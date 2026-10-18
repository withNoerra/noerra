// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IEarnedDiemReserveConfiguration, IEarnedDiemPool} from "./NoerraEarnedDiemReserve.sol";

/// @notice Holds the exact reserve creation code as non-executable data (STOP-prefixed), so the factory stays under
/// the contract size limit and the Ethereum escrow deployer can pin the same bytes.
contract NoerraEarnedDiemReserveCode {
    constructor(bytes memory creation) {
        require(creation.length > 0 && creation.length < 49152, "Creation code size");
        bytes memory code = abi.encodePacked(hex"00", creation);
        assembly ("memory-safe") { return(add(code, 32), mload(code)) }
    }
}

/// @notice Deterministic per-agent brain-fund reserves on Base. A reserve's address depends only on this factory and
/// the agentId (CREATE2 salt = agentId, initcode = reserve creation code + agentId), so Ethereum escrows can bridge to it
/// before it exists. Anyone may deploy any agent's reserve; the result is the same contract at the same address.
/// @dev No owner and no setters. Shared infrastructure is pinned by code hash at construction; the reserve re-checks it.
contract NoerraEarnedDiemReserveFactory is IEarnedDiemReserveConfiguration {
    Infrastructure private config;
    Route private path;
    Bounds private limits;
    Pins private hashes;

    /// @dev Uniswap's own maximum. One observation per 2-s Base block: 65,535 covers 36 h, so dust swaps every block
    /// cannot age the 4-hour window out (it needs 7,200 slots; the keeper targets 2x that only if a buy hits OLD).
    uint16 public constant MAX_ORACLE_CARDINALITY = type(uint16).max;
    /// @notice Container holding the reserve creation code, and that code's hash (the CREATE2 initcode prefix).
    address public immutable reserveCode;
    bytes32 public immutable reserveCreationCodeHash;

    event ReserveDeployed(bytes32 indexed agentId, address indexed reserve);

    constructor(Infrastructure memory i, Route memory r, Bounds memory b, address code) {
        require(block.chainid == 8453, "Base only");
        reserveCode = code;
        bytes memory creation = _creation(code);
        reserveCreationCodeHash = keccak256(creation);
        require(
            address(i.dollar).code.length > 0 && address(i.diem).code.length > 0
                && address(i.mirrors).code.length > 0 && address(i.transmitter).code.length > 0
                && address(i.tokenMessenger).code.length > 0 && address(i.router).code.length > 0
                && address(i.quoter).code.length > 0 && address(i.dollar) != address(i.diem),
            "Base infrastructure"
        );
        require(
            i.sourceDollar != address(0) && i.sourceTokenMessenger != address(0) && i.platform != address(0)
                && i.mirrors.sourceChainId() == 1,
            "Source identity and platform"
        );
        require(r.diemPool.code.length > 0, "DIEM pool");
        address diemOther = r.hopToken == address(0) ? address(i.dollar) : r.hopToken;
        _pool(r.diemPool, address(i.diem), diemOther, r.diemFee);
        if (r.hopToken == address(0)) {
            require(r.hopPool == address(0) && r.hopFee == 0, "Direct route");
        } else {
            require(
                r.hopPool.code.length > 0 && r.hopToken != address(i.dollar) && r.hopToken != address(i.diem),
                "Hop pool"
            );
            _pool(r.hopPool, r.hopToken, address(i.dollar), r.hopFee);
        }
        require(
            b.slippageBps <= 500 && b.twapWindow >= 60 && b.longWindow >= 2 * b.twapWindow && b.longWindow <= 1 days
                && b.maxTickDeviation > 0 && b.maxTickDeviation <= 2000 && b.maxLongTickDeviation > 0
                && b.maxLongTickDeviation <= 2000 && b.minimumReturnUSDC > b.maxReturnFee
                && uint256(b.longWindow) <= MAX_ORACLE_CARDINALITY, // 2x the window in 2-s blocks fits the history
            "Reviewed buy and return bounds"
        );
        for (uint256 k; k < 2; ++k) {
            address v = i.signatureVerifiers[k];
            require(
                v == address(0)
                    || (v.code.length > 0 && v != address(i.dollar) && v != address(i.diem) && v != r.hopToken
                        && v != address(i.router) && v != address(i.quoter) && v != address(i.tokenMessenger)
                        && v != address(i.transmitter) && v != r.diemPool && v != r.hopPool
                        && v != 0x000000000022D473030F116dDEE9F6B43aC78BA3),
                "Signature verifier is not an asset or infrastructure contract"
            );
        }
        config = i;
        path = r;
        limits = b;
        hashes = Pins(
            address(i.dollar).codehash,
            address(i.diem).codehash,
            address(i.transmitter).codehash,
            address(i.tokenMessenger).codehash,
            address(i.router).codehash,
            address(i.quoter).codehash
        );
    }

    function _pool(address pool, address a, address b, uint24 fee) private view {
        IEarnedDiemPool p = IEarnedDiemPool(pool);
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        require(p.token0() == t0 && p.token1() == t1 && p.fee() == fee, "Pinned pool tokens and fee");
    }

    function infrastructure() external view returns (Infrastructure memory) {
        return config;
    }

    function route() external view returns (Route memory) {
        return path;
    }

    function bounds() external view returns (Bounds memory) {
        return limits;
    }

    function pins() external view returns (Pins memory) {
        return hashes;
    }

    /// @notice Permissionless: grows both pinned pools' oracle history so the 30-minute and long windows stay
    /// observable on fresh or quiet pools (Uniswap only ever increases it; the caller pays the slot gas).
    function prepareOracles(uint16 cardinality) external {
        require(cardinality > 0 && cardinality <= MAX_ORACLE_CARDINALITY, "Bounded oracle cardinality");
        IEarnedDiemPool(path.diemPool).increaseObservationCardinalityNext(cardinality);
        if (path.hopPool != address(0)) IEarnedDiemPool(path.hopPool).increaseObservationCardinalityNext(cardinality);
    }

    function _creation(address container) private view returns (bytes memory creation) {
        uint256 n = container.code.length;
        require(n > 1, "Reserve code container");
        bytes memory first = new bytes(1);
        assembly ("memory-safe") { extcodecopy(container, add(first, 32), 0, 1) }
        require(first[0] == bytes1(0), "Reserve code container");
        creation = new bytes(n - 1);
        assembly ("memory-safe") { extcodecopy(container, add(creation, 32), 1, sub(n, 1)) }
    }

    function _initCode(bytes32 agentId) private view returns (bytes memory) {
        return abi.encodePacked(_creation(reserveCode), abi.encode(agentId));
    }

    /// @notice The reserve's CREATE2 initcode hash for one agent: keccak256(creation code ++ abi.encode(agentId)).
    function initCodeHash(bytes32 agentId) public view returns (bytes32) {
        return keccak256(_initCode(agentId));
    }

    /// @notice Where agentId's reserve lives (whether or not it has been deployed yet).
    function reserveAddress(bytes32 agentId) public view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), agentId, initCodeHash(agentId)))))
        );
    }

    /// @notice Permissionless and idempotent: deploys agentId's reserve if it does not exist yet.
    function deploy(bytes32 agentId) external returns (address reserve) {
        reserve = reserveAddress(agentId);
        if (reserve.code.length > 0) return reserve;
        bytes memory init = _initCode(agentId);
        address deployed;
        assembly ("memory-safe") { deployed := create2(0, add(init, 32), mload(init), agentId) }
        require(deployed == reserve && deployed.code.length > 0, "Deterministic reserve");
        emit ReserveDeployed(agentId, reserve);
    }
}
