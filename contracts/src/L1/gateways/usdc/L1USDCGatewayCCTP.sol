// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import {IFiatToken} from "../../../interfaces/IFiatToken.sol";
import {ITokenMessenger} from "../../../interfaces/ITokenMessenger.sol";
import {IL2ERC20Gateway} from "../../../L2/gateways/IL2ERC20Gateway.sol";
import {IL1ScrollMessenger} from "../../IL1ScrollMessenger.sol";
import {IL1ERC20Gateway} from "../IL1ERC20Gateway.sol";

import {CCTPGatewayBase} from "../../../libraries/gateway/CCTPGatewayBase.sol";
import {ScrollGatewayBase} from "../../../libraries/gateway/ScrollGatewayBase.sol";
import {L1ERC20Gateway} from "../L1ERC20Gateway.sol";

/// @title L1USDCGatewayCCTP
/// @notice The `L1USDCGateway` contract is used to deposit `USDC` token in layer 1 and
/// finalize withdraw `USDC` from layer 2, after USDC become native in layer 2.
contract L1USDCGatewayCCTP is OwnableUpgradeable, CCTPGatewayBase, L1ERC20Gateway {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /***************
     * Constructor *
     ***************/

    constructor(
        address _l1USDC,
        address _l2USDC,
        uint32 _destinationDomain
    ) CCTPGatewayBase(_l1USDC, _l2USDC, _destinationDomain) {}

    /// @notice Initialize the storage of L1USDCGatewayCCTP.
    /// @param _counterpart The address of L2USDCGatewayCCTP in L2.
    /// @param _router The address of L1GatewayRouter.
    /// @param _messenger The address of L1ScrollMessenger.
    /// @param _cctpMessenger The address of TokenMessenger in local domain.
    /// @param _cctpTransmitter The address of MessageTransmitter in local domain.
    function initialize(
        address _counterpart,
        address _router,
        address _messenger,
        address _cctpMessenger,
        address _cctpTransmitter
    ) external initializer {
        require(_router != address(0), "zero router address");
        ScrollGatewayBase._initialize(_counterpart, _router, _messenger);
        CCTPGatewayBase._initialize(_cctpMessenger, _cctpTransmitter);

        OwnableUpgradeable.__Ownable_init();
    }

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IL1ERC20Gateway
    function getL2ERC20Address(address) public view override returns (address) {
        return l2USDC;
    }

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice Relay cross chain message and claim USDC that has been cross chained.
    /// @dev The `_scrollMessage` is actually encoded calldata for `L1ScrollMessenger.relayMessageWithProof`.
    /// @param _nonce The nonce of the message from CCTP.
    /// @param _cctpMessage The message passed to MessageTransmitter contract in CCTP.
    /// @param _cctpSignature The message passed to MessageTransmitter contract in CCTP.
    /// @param _scrollMessage The message passed to L1ScrollMessenger contract.
    function relayAndClaimUSDC(
        uint256 _nonce,
        bytes calldata _cctpMessage,
        bytes calldata _cctpSignature,
        bytes calldata _scrollMessage
    ) external {
        require(status[_nonce] == CCTPMessageStatus.None, "message relayed");
        // call messenger to set `status[_nonce]` to `CCTPMessageStatus.Pending`.
        (bool _success, ) = messenger.call(_scrollMessage);
        require(_success, "call messenger failed");
        require(status[_nonce] == CCTPMessageStatus.Pending, "message relay failed");

        claimUSDC(_nonce, _cctpMessage, _cctpSignature);
    }

    /// @inheritdoc IL1ERC20Gateway
    /// @dev The function will not mint the USDC, users need to call `claimUSDC` after this function is done.
    function finalizeWithdrawERC20(
        address _l1Token,
        address _l2Token,
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _data
    ) external payable override onlyCallByCounterpart {
        require(msg.value == 0, "nonzero msg.value");
        require(_l1Token == l1USDC, "l1 token not USDC");
        require(_l2Token == l2USDC, "l2 token not USDC");

        uint256 _nonce;
        (_nonce, _data) = abi.decode(_data, (uint256, bytes));
        require(status[_nonce] == CCTPMessageStatus.None, "message relayed");
        status[_nonce] = CCTPMessageStatus.Pending;

        emit FinalizeWithdrawERC20(_l1Token, _l2Token, _from, _to, _amount, _data);
    }

    /*******************************
     * Public Restricted Functions *
     *******************************/

    /// @notice Update the CCTP contract addresses.
    /// @param _messenger The address of TokenMessenger in local domain.
    /// @param _transmitter The address of MessageTransmitter in local domain.
    function updateCCTPContracts(address _messenger, address _transmitter) external onlyOwner {
        cctpMessenger = _messenger;
        cctpTransmitter = _transmitter;
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @inheritdoc L1ERC20Gateway
    function _deposit(
        address _token,
        address _to,
        uint256 _amount,
        bytes memory _data,
        uint256 _gasLimit
    ) internal virtual override nonReentrant {
        require(_amount > 0, "deposit zero amount");
        require(_token == l1USDC, "only USDC is allowed");

        // 1. Extract real sender if this call is from L1GatewayRouter.
        address _from = msg.sender;
        if (router == msg.sender) {
            (_from, _data) = abi.decode(_data, (address, bytes));
        }

        // 2. Transfer token into this contract.
        IERC20Upgradeable(_token).safeTransferFrom(_from, address(this), _amount);

        // 3. Burn token through CCTP TokenMessenger
        uint256 _nonce = ITokenMessenger(cctpMessenger).depositForBurnWithCaller(
            _amount,
            destinationDomain,
            bytes32(uint256(uint160(_to))),
            address(this),
            bytes32(uint256(uint160(counterpart)))
        );

        // 4. Generate message passed to L2USDCGatewayCCTP.
        bytes memory _message = abi.encodeWithSelector(
            IL2ERC20Gateway.finalizeDepositERC20.selector,
            _token,
            l2USDC,
            _from,
            _to,
            _amount,
            abi.encode(_nonce, _data)
        );

        // 4. Send message to L1ScrollMessenger.
        IL1ScrollMessenger(messenger).sendMessage{value: msg.value}(counterpart, 0, _message, _gasLimit);

        emit DepositERC20(_token, l2USDC, _from, _to, _amount, _data);
    }
}
