// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NoerraAgentRegistry, NoerraAgentAccount, NoerraAgentCredits, NoerraCreationToken} from "./NoerraAgents.sol";
import {NoerraLockedCreation, NoerraBackers} from "./NoerraLaunchpad.sol";
import {NoerraDiem} from "./NoerraDiem.sol";
import {NoerraDiemCreation, NoerraDiemCreationDeployer, NoerraDiemBackingReader} from "./NoerraDiemLaunchpad.sol";

/// @dev Keeps creation bytecode out of the launchpad. The immutable reader's
///      one-time binding authorizes the only factory that can use this builder.
contract NoerraCashCreationDeployer {
    NoerraDiem public immutable wrapper;
    IPoolManager public immutable manager;
    constructor(NoerraDiem wrapper_, IPoolManager manager_) { wrapper = wrapper_; manager = manager_; }
    function deploy(bytes32 id) external returns (NoerraLockedCreation) {
        NoerraDualLaunchpad factory = NoerraDualLaunchpad(msg.sender);
        require(address(NoerraDiemBackingReader(address(wrapper.backingReader())).factory()) == msg.sender, "Frozen factory only");
        return new NoerraLockedCreation(manager, NoerraAgentAccount(wrapper.registry().accounts(id)),
            factory.credits(), factory.credits().dollar(), factory.protocolTreasury(), factory.noerTreasury(), msg.sender);
    }
}

/// @notice One token, two permanent pools, one registered agent. Dollar fees
///         fund its cash account; nDIEM fees grow its renewable inference stake.
///         Both markets and activation are atomic: no half-created launch.
contract NoerraDualLaunchpad is ReentrancyGuard {
    using SafeERC20 for IERC20;
    NoerraAgentRegistry public immutable registry;
    NoerraAgentCredits public immutable credits;
    NoerraDiem public immutable wrapper;
    IPoolManager public immutable manager;
    NoerraDiemCreationDeployer public immutable creationDeployer;
    NoerraCashCreationDeployer public immutable cashDeployer;
    address public immutable protocolTreasury;
    address public immutable noerTreasury;
    uint256 public constant ACTIVATION_FLOOR = 0.1 ether;
    mapping(bytes32 => NoerraDiemCreation) public launches;
    mapping(bytes32 => NoerraLockedCreation) public cashLaunches;
    bytes32[] public agentIds;
    struct Funding { uint256 cashSeed; uint256 diemSeed; uint256 activation; uint256 operatingCash; }
    event TokenLaunched(bytes32 indexed agentId, address indexed token, address locker, address backers);
    event DualLaunched(bytes32 indexed agentId, address indexed token, address cashMarket, address diemMarket, uint256 lockedActivation);
    event GasSeeded(bytes32 indexed agentId, address indexed signer, uint256 amount);

    constructor(NoerraAgentRegistry registry_, NoerraAgentCredits credits_, NoerraDiem wrapper_, IPoolManager manager_,
        NoerraDiemCreationDeployer diemBuilder_, NoerraCashCreationDeployer cashBuilder_, address protocol_, address noer_) {
        require(address(registry_) == address(wrapper_.registry()) && address(registry_) == address(credits_.registry())
            && address(registry_.dollar()) == address(credits_.dollar()), "Registry wiring");
        require(address(manager_).code.length > 0 && protocol_ != address(0) && noer_ != address(0), "Pinned deployment");
        require(address(diemBuilder_.wrapper()) == address(wrapper_) && address(diemBuilder_.manager()) == address(manager_)
            && address(cashBuilder_.wrapper()) == address(wrapper_) && address(cashBuilder_.manager()) == address(manager_), "Builder wiring");
        registry = registry_; credits = credits_; wrapper = wrapper_; manager = manager_;
        creationDeployer = diemBuilder_; cashDeployer = cashBuilder_; protocolTreasury = protocol_; noerTreasury = noer_;
    }
    function count() external view returns (uint256) { return agentIds.length; }

    function launch(bytes32 id, string calldata name, string calldata symbol, Funding calldata funds)
        external payable nonReentrant returns (NoerraLockedCreation cash, NoerraDiemCreation brain) {
        address account = registry.accounts(id);
        require(account != address(0) && NoerraAgentAccount(account).human() == msg.sender, "Agent human only");
        require(address(launches[id]) == address(0) && registry.tokens(id) == address(0), "One creation token");
        require(address(NoerraDiemBackingReader(address(wrapper.backingReader())).factory()) == address(this), "Reader not bound");
        require(funds.activation >= ACTIVATION_FLOOR, "Permanent activation floor");
        require(funds.operatingCash >= NoerraAgentAccount(account).hostingReserve() + 10e6, "Fund hosting reserve and startup");
        require(msg.value >= 0.0001 ether && msg.value <= 0.01 ether, "Bounded startup gas");
        cash = cashDeployer.deploy(id); brain = creationDeployer.deploy(id);
        IERC20 token = IERC20(address(new NoerraCreationToken(name, symbol, address(this))));
        token.safeTransfer(address(cash), 500_000_000 ether); token.safeTransfer(address(brain), 500_000_000 ether);
        NoerraBackers cashBackers = new NoerraBackers(token, IERC20(address(credits)), address(cash));
        NoerraBackers diemBackers = new NoerraBackers(token, IERC20(address(wrapper)), address(brain));
        cashLaunches[id] = cash; launches[id] = brain; agentIds.push(id);
        credits.dollar().safeTransferFrom(msg.sender, address(cash), funds.cashSeed);
        IERC20(address(wrapper)).safeTransferFrom(msg.sender, address(brain), funds.diemSeed);
        cash.initializeHalf(token, cashBackers, funds.cashSeed); brain.initializeHalf(token, diemBackers, funds.diemSeed);
        IERC20(address(wrapper)).safeTransferFrom(msg.sender, address(this), funds.activation);
        wrapper.lockFor(id, funds.activation); wrapper.reconcile(id);
        credits.dollar().safeTransferFrom(msg.sender, account, funds.operatingCash);
        address signer = NoerraAgentAccount(account).signer();
        require(signer.code.length == 0, "Operating EOA");
        (bool sent,) = payable(signer).call{value: msg.value}(""); require(sent, "Startup gas delivery");
        emit GasSeeded(id, signer, msg.value);
        emit TokenLaunched(id, address(token), address(brain), address(diemBackers));
        emit DualLaunched(id, address(token), address(cash), address(brain), funds.activation);
    }
}
