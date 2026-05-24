import { ethers, network, run } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = (await ethers.provider.getNetwork()).chainId;

  console.log(`Deploying with ${deployer.address}`);
  console.log(`Network: ${network.name} (chainId ${chainId})`);

  const Reputation = await ethers.getContractFactory("ReputationSystem");
  const reputation = await Reputation.deploy();
  await reputation.waitForDeployment();
  const reputationAddr = await reputation.getAddress();
  console.log(`ReputationSystem: ${reputationAddr}`);

  const Market = await ethers.getContractFactory("WorldCupBetting");
  const market = await Market.deploy(reputationAddr);
  await market.waitForDeployment();
  const marketAddr = await market.getAddress();
  console.log(`WorldCupBetting:  ${marketAddr}`);

  const linkTx = await reputation.setPredictionMarket(marketAddr);
  await linkTx.wait();
  console.log(`Linked ReputationSystem -> WorldCupBetting`);

  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const usdc = await MockERC20.deploy("Mock USDC", "mUSDC");
  await usdc.waitForDeployment();
  const usdcAddr = await usdc.getAddress();
  console.log(`MockERC20:        ${usdcAddr}`);

  const record = {
    network: network.name,
    chainId: Number(chainId),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      ReputationSystem: reputationAddr,
      WorldCupBetting: marketAddr,
      MockERC20: usdcAddr,
    },
  };

  const outDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${network.name}.json`);
  fs.writeFileSync(outFile, JSON.stringify(record, null, 2));
  console.log(`\nWrote ${outFile}`);

  if (network.name === "sepolia") {
    console.log("\nWaiting 30s before Etherscan verification...");
    await new Promise((r) => setTimeout(r, 30_000));

    const targets: Array<[string, string, any[]]> = [
      ["ReputationSystem", reputationAddr, []],
      ["WorldCupBetting", marketAddr, [reputationAddr]],
      ["MockERC20", usdcAddr, ["Mock USDC", "mUSDC"]],
    ];

    for (const [name, address, args] of targets) {
      try {
        await run("verify:verify", { address, constructorArguments: args });
        console.log(`Verified ${name}`);
      } catch (err: any) {
        const msg = err?.message ?? String(err);
        if (msg.toLowerCase().includes("already verified")) {
          console.log(`${name} already verified`);
        } else {
          console.warn(`Verify ${name} failed: ${msg}`);
        }
      }
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
