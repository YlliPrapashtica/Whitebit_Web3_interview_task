import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("WorldCupBetting (additional unit tests)", function () {
  let market: any;
  let reputation: any;
  let usdc: any;
  let owner: any;
  let arbitrator: any;
  let user: any;
  let other: any;

  beforeEach(async function () {
    [owner, arbitrator, user, other] = await ethers.getSigners();

    const Reputation = await ethers.getContractFactory("ReputationSystem");
    reputation = await Reputation.deploy();
    await reputation.waitForDeployment();

    const Market = await ethers.getContractFactory("WorldCupBetting");
    market = await Market.deploy(await reputation.getAddress());
    await market.waitForDeployment();

    await reputation.setPredictionMarket(await market.getAddress());

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    usdc = await MockERC20.deploy("Mock USDC", "mUSDC");
    await usdc.waitForDeployment();
  });

  async function futureTime(offset = 86400): Promise<number> {
    return (await time.latest()) + offset;
  }

  describe("createMarket validation", function () {
    it("rejects fewer than 2 outcomes", async function () {
      await expect(
        market.createMarket(
          "q", "d", ["only"], await futureTime(), arbitrator.address, ethers.ZeroAddress
        )
      ).to.be.revertedWith("Need at least 2 outcomes");
    });

    it("rejects more than MAX_OUTCOMES outcomes", async function () {
      const tooMany = Array.from({ length: 11 }, (_, i) => `o${i}`);
      await expect(
        market.createMarket(
          "q", "d", tooMany, await futureTime(), arbitrator.address, ethers.ZeroAddress
        )
      ).to.be.revertedWith("Too many outcomes");
    });

    it("rejects empty outcome label", async function () {
      await expect(
        market.createMarket(
          "q", "d", ["yes", ""], await futureTime(), arbitrator.address, ethers.ZeroAddress
        )
      ).to.be.revertedWith("Empty outcome");
    });

    it("rejects past resolution time", async function () {
      const past = (await time.latest()) - 1;
      await expect(
        market.createMarket(
          "q", "d", ["yes", "no"], past, arbitrator.address, ethers.ZeroAddress
        )
      ).to.be.revertedWith("Resolution must be in future");
    });

    it("rejects zero-address arbitrator", async function () {
      await expect(
        market.createMarket(
          "q", "d", ["yes", "no"], await futureTime(), ethers.ZeroAddress, ethers.ZeroAddress
        )
      ).to.be.revertedWith("Invalid arbitrator");
    });
  });

  describe("placeBet validation", function () {
    it("rejects zero amount", async function () {
      await market.createMarket(
        "q", "d", ["yes", "no"], await futureTime(), arbitrator.address, ethers.ZeroAddress
      );
      await expect(
        market.connect(user).placeBet(1, 0, 0, 0, { value: 0 })
      ).to.be.revertedWith("Amount must be > 0");
    });

    it("rejects ETH sent to ERC20 market", async function () {
      const tokenAddr = await usdc.getAddress();
      await market.createMarket(
        "q", "d", ["yes", "no"], await futureTime(), arbitrator.address, tokenAddr
      );
      const amount = ethers.parseUnits("10", 18);
      await usdc.mint(user.address, amount);
      await usdc.connect(user).approve(await market.getAddress(), amount);
      await expect(
        market.connect(user).placeBet(1, 0, amount, 0, { value: 1n })
      ).to.be.revertedWith("No ETH for ERC20 market");
    });
  });

  describe("claimWinnings access", function () {
    it("reverts when caller is not the current bet owner", async function () {
      const resolution = await futureTime();
      await market.createMarket(
        "q", "d", ["yes", "no"], resolution, arbitrator.address, ethers.ZeroAddress
      );
      const stake = ethers.parseEther("0.1");
      await market.connect(user).placeBet(1, 0, stake, 0, { value: stake });
      await time.increaseTo(resolution + 1);
      await market.connect(arbitrator).resolveMarket(1, 0);

      const bets = await market.getMarketBets(1);
      await expect(
        market.connect(other).claimWinnings(bets[0])
      ).to.be.revertedWith("Not your bet");
    });
  });

  describe("cancelListing", function () {
    it("clears the listing so buyPosition reverts afterward", async function () {
      await market.createMarket(
        "q", "d", ["yes", "no"], await futureTime(), arbitrator.address, ethers.ZeroAddress
      );
      const stake = ethers.parseEther("0.1");
      await market.connect(user).placeBet(1, 0, stake, 0, { value: stake });
      const bets = await market.getUserBets(user.address);
      const betId = bets[bets.length - 1];

      await market.connect(user).listPosition(betId, ethers.parseEther("0.15"));
      await market.connect(user).cancelListing(betId);

      await expect(
        market.connect(other).buyPosition(betId, { value: ethers.parseEther("0.15") })
      ).to.be.revertedWith("Position not for sale");
    });
  });

  describe("ERC20 secondary market", function () {
    it("buyPosition transfers ownership and ERC20 collateral", async function () {
      const tokenAddr = await usdc.getAddress();
      await market.createMarket(
        "q", "d", ["yes", "no"], await futureTime(), arbitrator.address, tokenAddr
      );

      const stake = ethers.parseUnits("50", 18);
      const price = ethers.parseUnits("60", 18);

      await usdc.mint(user.address, stake);
      await usdc.connect(user).approve(await market.getAddress(), stake);
      await market.connect(user).placeBet(1, 0, stake, 0);

      const userBets = await market.getUserBets(user.address);
      const betId = userBets[userBets.length - 1];

      await market.connect(user).listPosition(betId, price);

      await usdc.mint(other.address, price);
      await usdc.connect(other).approve(await market.getAddress(), price);

      const sellerBefore = await usdc.balanceOf(user.address);
      await market.connect(other).buyPosition(betId);
      const sellerAfter = await usdc.balanceOf(user.address);

      expect(sellerAfter - sellerBefore).to.equal(price);
    });
  });

  describe("withdrawFees", function () {
    it("reverts when there are no fees", async function () {
      await expect(
        market.connect(owner).withdrawFees(ethers.ZeroAddress)
      ).to.be.revertedWith("No fees to withdraw");
    });
  });
});
