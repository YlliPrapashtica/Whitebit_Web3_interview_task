// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IReputationSystem {
    function updateReputation(address user, bool correct) external;
    function getReputation(address user) external view returns (uint256);
}

contract WorldCupBetting is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    enum MarketStatus { Open, Closed, Resolved, Cancelled }

    struct Market {
        uint256 id;
        string question;
        string description;
        string[] outcomes;
        uint256 resolutionTime;
        address arbitrator;
        address creator;
        uint256 createdAt;
        MarketStatus status;
        uint256 winningOutcome;
        address tokenAddress;
        uint256 totalVolume;
    }

    struct Bet {
        uint256 id;
        address bettor;
        uint256 marketId;
        uint256 outcomeIndex;
        uint256 amount;
        uint256 shares;
        uint256 timestamp;
        bool claimed;
    }

    uint256 public constant PLATFORM_FEE_BPS = 200;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_OUTCOMES = 10;

    IReputationSystem public immutable reputationSystem;

    uint256 public marketCount;
    uint256 public betCount;

    mapping(uint256 => Market) public markets;
    mapping(uint256 => Bet) public bets;
    mapping(uint256 => mapping(uint256 => uint256)) public outcomePools;
    mapping(uint256 => mapping(uint256 => uint256)) public outcomeShares;
    mapping(address => uint256[]) public userBets;
    mapping(uint256 => uint256[]) public marketBets;
    mapping(uint256 => bool) public positionsForSale;
    mapping(uint256 => uint256) public positionPrices;
    mapping(address => uint256) public collectedFees;

    event MarketCreated(uint256 indexed marketId, address indexed creator, string question);
    event BetPlaced(uint256 indexed betId, uint256 indexed marketId, address indexed bettor, uint256 amount);
    event MarketResolved(uint256 indexed marketId, uint256 winningOutcome);
    event WinningsClaimed(uint256 indexed betId, address indexed claimer, uint256 amount);
    event PositionListed(uint256 indexed betId, uint256 price);
    event PositionSold(uint256 indexed betId, address seller, address buyer, uint256 price);
    event FeesWithdrawn(address indexed token, uint256 amount, address indexed to);

    constructor(address _reputationSystem) Ownable(msg.sender) {
        reputationSystem = IReputationSystem(_reputationSystem);
    }

    function createMarket(
        string memory _question,
        string memory _description,
        string[] memory _outcomes,
        uint256 _resolutionTime,
        address _arbitrator,
        address _tokenAddress
    ) external returns (uint256) {
        require(_outcomes.length >= 2, "Need at least 2 outcomes");
        require(_outcomes.length <= MAX_OUTCOMES, "Too many outcomes");
        require(_resolutionTime > block.timestamp, "Resolution must be in future");
        require(_arbitrator != address(0), "Invalid arbitrator");
        for (uint256 i = 0; i < _outcomes.length; i++) {
            require(bytes(_outcomes[i]).length > 0, "Empty outcome");
        }

        marketCount++;
        Market storage m = markets[marketCount];
        m.id = marketCount;
        m.question = _question;
        m.description = _description;
        m.outcomes = _outcomes;
        m.resolutionTime = _resolutionTime;
        m.arbitrator = _arbitrator;
        m.creator = msg.sender;
        m.createdAt = block.timestamp;
        m.status = MarketStatus.Open;
        m.tokenAddress = _tokenAddress;

        emit MarketCreated(marketCount, msg.sender, _question);
        return marketCount;
    }

    function placeBet(
        uint256 _marketId,
        uint256 _outcomeIndex,
        uint256 _amount,
        uint256 _minShares
    ) external payable nonReentrant returns (uint256) {
        Market storage m = markets[_marketId];
        require(m.status == MarketStatus.Open, "Market not open");
        require(block.timestamp < m.resolutionTime, "Market closed");
        require(_outcomeIndex < m.outcomes.length, "Invalid outcome");
        require(_amount > 0, "Amount must be > 0");

        if (m.tokenAddress == address(0)) {
            require(msg.value == _amount, "Incorrect ETH amount");
        } else {
            require(msg.value == 0, "No ETH for ERC20 market");
            IERC20(m.tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        }

        uint256 shares = calculateShares(_marketId, _outcomeIndex, _amount);
        require(shares >= _minShares, "Slippage exceeded");

        betCount++;
        Bet storage b = bets[betCount];
        b.id = betCount;
        b.bettor = msg.sender;
        b.marketId = _marketId;
        b.outcomeIndex = _outcomeIndex;
        b.amount = _amount;
        b.shares = shares;
        b.timestamp = block.timestamp;

        outcomePools[_marketId][_outcomeIndex] += _amount;
        outcomeShares[_marketId][_outcomeIndex] += shares;
        m.totalVolume += _amount;

        userBets[msg.sender].push(betCount);
        marketBets[_marketId].push(betCount);

        emit BetPlaced(betCount, _marketId, msg.sender, _amount);
        return betCount;
    }

    function resolveMarket(uint256 _marketId, uint256 _winningOutcome) external {
        Market storage m = markets[_marketId];
        require(msg.sender == m.arbitrator, "Only arbitrator");
        require(m.status == MarketStatus.Open, "Market not open");
        require(block.timestamp >= m.resolutionTime, "Too early");
        require(_winningOutcome < m.outcomes.length, "Invalid outcome");

        m.status = MarketStatus.Resolved;
        m.winningOutcome = _winningOutcome;

        emit MarketResolved(_marketId, _winningOutcome);
    }

    function claimWinnings(uint256 _betId) external nonReentrant {
        Bet storage b = bets[_betId];
        Market storage m = markets[b.marketId];
        require(msg.sender == b.bettor, "Not your bet");
        require(!b.claimed, "Already claimed");
        require(m.status == MarketStatus.Resolved, "Market not resolved");

        b.claimed = true;

        if (b.outcomeIndex == m.winningOutcome) {
            uint256 totalWinningShares = outcomeShares[b.marketId][m.winningOutcome];
            uint256 totalPool = getTotalPool(b.marketId);
            uint256 gross = (b.shares * totalPool) / totalWinningShares;
            uint256 fee = (gross * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
            uint256 net = gross - fee;

            collectedFees[m.tokenAddress] += fee;
            reputationSystem.updateReputation(msg.sender, true);

            if (m.tokenAddress == address(0)) {
                (bool ok, ) = payable(msg.sender).call{value: net}("");
                require(ok, "ETH transfer failed");
            } else {
                IERC20(m.tokenAddress).safeTransfer(msg.sender, net);
            }

            emit WinningsClaimed(_betId, msg.sender, net);
        } else {
            reputationSystem.updateReputation(msg.sender, false);
        }
    }

    function listPosition(uint256 _betId, uint256 _price) external {
        Bet storage b = bets[_betId];
        require(msg.sender == b.bettor, "Not your bet");
        require(!b.claimed, "Bet already claimed");
        require(markets[b.marketId].status == MarketStatus.Open, "Market not open");

        positionsForSale[_betId] = true;
        positionPrices[_betId] = _price;

        emit PositionListed(_betId, _price);
    }

    function cancelListing(uint256 _betId) external {
        Bet storage b = bets[_betId];
        require(msg.sender == b.bettor, "Not your bet");
        require(positionsForSale[_betId], "Not listed");

        positionsForSale[_betId] = false;
        positionPrices[_betId] = 0;

        emit PositionListed(_betId, 0);
    }

    function buyPosition(uint256 _betId) external payable nonReentrant {
        require(positionsForSale[_betId], "Position not for sale");

        Bet storage b = bets[_betId];
        Market storage m = markets[b.marketId];
        address seller = b.bettor;
        uint256 price = positionPrices[_betId];

        b.bettor = msg.sender;
        positionsForSale[_betId] = false;
        positionPrices[_betId] = 0;
        userBets[msg.sender].push(_betId);

        if (m.tokenAddress == address(0)) {
            require(msg.value >= price, "Insufficient ETH");
            (bool ok, ) = payable(seller).call{value: price}("");
            require(ok, "ETH transfer failed");
            if (msg.value > price) {
                (bool refundOk, ) = payable(msg.sender).call{value: msg.value - price}("");
                require(refundOk, "Refund failed");
            }
        } else {
            require(msg.value == 0, "No ETH for ERC20 market");
            IERC20(m.tokenAddress).safeTransferFrom(msg.sender, seller, price);
        }

        emit PositionSold(_betId, seller, msg.sender, price);
    }

    function withdrawFees(address _tokenAddress) external onlyOwner nonReentrant {
        uint256 fees = collectedFees[_tokenAddress];
        require(fees > 0, "No fees to withdraw");

        collectedFees[_tokenAddress] = 0;

        if (_tokenAddress == address(0)) {
            (bool ok, ) = payable(owner()).call{value: fees}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(_tokenAddress).safeTransfer(owner(), fees);
        }

        emit FeesWithdrawn(_tokenAddress, fees, owner());
    }

    function getAvailableFees(address _tokenAddress) external view returns (uint256) {
        return collectedFees[_tokenAddress];
    }

    function calculateShares(uint256 _marketId, uint256 _outcomeIndex, uint256 _amount)
        public view returns (uint256)
    {
        uint256 currentPool = outcomePools[_marketId][_outcomeIndex];
        if (currentPool == 0) return _amount * 100;
        uint256 totalPool = getTotalPool(_marketId);
        uint256 newPool = currentPool + _amount;
        return (_amount * 100 * totalPool) / (newPool * currentPool);
    }

    function getPrice(uint256 _marketId, uint256 _outcomeIndex)
        public view returns (uint256)
    {
        uint256 pool = outcomePools[_marketId][_outcomeIndex];
        uint256 total = getTotalPool(_marketId);
        if (total == 0) return 50;
        return (pool * 100) / total;
    }

    function getTotalPool(uint256 _marketId) public view returns (uint256) {
        Market storage m = markets[_marketId];
        uint256 total = 0;
        for (uint256 i = 0; i < m.outcomes.length; i++) {
            total += outcomePools[_marketId][i];
        }
        return total;
    }

    function getUserBets(address _user) external view returns (uint256[] memory) {
        return userBets[_user];
    }

    function getMarketBets(uint256 _marketId) external view returns (uint256[] memory) {
        return marketBets[_marketId];
    }

    function getMarket(uint256 _marketId)
        external
        view
        returns (
            uint256 id,
            string memory question,
            string memory description,
            string[] memory outcomes,
            uint256 resolutionTime,
            address arbitrator,
            address creator,
            MarketStatus status,
            uint256 totalVolume,
            address tokenAddress
        )
    {
        Market storage m = markets[_marketId];
        return (
            m.id,
            m.question,
            m.description,
            m.outcomes,
            m.resolutionTime,
            m.arbitrator,
            m.creator,
            m.status,
            m.totalVolume,
            m.tokenAddress
        );
    }
}
