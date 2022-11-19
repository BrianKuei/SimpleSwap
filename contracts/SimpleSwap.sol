// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ISimpleSwap } from "./interface/ISimpleSwap.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./libraries/Math.sol";
import "./libraries/SimpleSwapV2Library.sol";
import "hardhat/console.sol";

contract SimpleSwap is ISimpleSwap, ERC20 {
    address public tokenA;
    address public tokenB;

    uint256 private reserve0;
    uint256 private reserve1;

    uint256 private _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1, "UniswapV2: LOCKED");
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    constructor(address _tokenA, address _tokenB) ERC20("SimpleSwap", "SIM") {
        require(_tokenA != address(0), "SimpleSwap: TOKENA_IS_NOT_CONTRACT");
        require(_tokenB != address(0), "SimpleSwap: TOKENB_IS_NOT_CONTRACT");
        require(_tokenA != _tokenB, "SimpleSwap: TOKENA_TOKENB_IDENTICAL_ADDRESS");

        tokenA = _tokenA;
        tokenB = _tokenB;
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        // bytes4(keccak256(bytes("transfer(address,uint256)")));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) private {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transferFrom failed");
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external override lock returns (uint256 amountOut) {
        require(tokenIn != address(0), "SimpleSwap: INVALID_TOKEN_IN");
        require(tokenOut != address(0), "SimpleSwap: INVALID_TOKEN_OUT");
        require(tokenIn != tokenOut, "SimpleSwap: IDENTICAL_ADDRESS");
        require(amountIn > 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");
        (address token0, address token1) = SimpleSwapV2Library.sortTokens(tokenIn, tokenOut);
        bool isTokenA = tokenIn == token0;
        bool isTokenB = tokenOut == token1;
        uint256 x = isTokenA ? reserve0 : reserve1;
        uint256 y = isTokenB ? reserve1 : reserve0;

        uint256 k = x * y;
        uint256 newAmountX = x + amountIn;
        uint256 newAmountY = k / newAmountX;
        amountOut = (amountIn * y) / newAmountX;

        require(amountOut > 0, "SimpleSwap: INSUFFICIENT_OUTPUT_AMOUNT");

        reserve0 = isTokenA ? newAmountX : newAmountY;
        reserve1 = isTokenB ? newAmountY : newAmountX;

        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        _safeTransfer(tokenOut, msg.sender, amountOut);

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _addLiquidity(uint256 amountAIn, uint256 amountBIn)
        internal
        virtual
        returns (uint256 amountA, uint256 amountB)
    {
        require(amountAIn != 0 && amountBIn != 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");
        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;

        if (_reserve0 == 0 && _reserve1 == 0) {
            (amountA, amountB) = (amountAIn, amountBIn);
        } else {
            uint256 amountBOptimal = SimpleSwapV2Library.quote(amountAIn, _reserve0, _reserve1);
            if (amountBOptimal <= amountBIn) {
                (amountA, amountB) = (amountAIn, amountBOptimal);
            } else {
                uint256 amountAOptimal = SimpleSwapV2Library.quote(amountBIn, _reserve1, _reserve0);
                assert(amountAOptimal <= amountAIn);
                (amountA, amountB) = (amountAOptimal, amountBIn);
            }
        }
    }

    function mint() internal lock returns (uint256 liquidity) {
        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;

        uint256 balance0 = IERC20(tokenA).balanceOf(address(this));
        uint256 balance1 = IERC20(tokenB).balanceOf(address(this));

        // 算出要新增的 token 數量（amount）
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1);
        } else {
            liquidity = Math.min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }
        require(liquidity > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(msg.sender, liquidity);

        reserve0 = balance0;
        reserve1 = balance1;
    }

    function addLiquidity(uint256 amountAIn, uint256 amountBIn)
        external
        override
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        (amountA, amountB) = _addLiquidity(amountAIn, amountBIn);
        //                                   to 應該是 pair token address
        _safeTransferFrom(tokenA, msg.sender, address(this), amountA);
        _safeTransferFrom(tokenB, msg.sender, address(this), amountB);
        liquidity = mint();
        emit AddLiquidity(msg.sender, amountA, amountB, liquidity);
    }

    function removeLiquidity(uint256 liquidity) external override returns (uint256 amountA, uint256 amountB) {
        require(liquidity != 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY_BURNED");
        address _token0 = tokenA;
        address _token1 = tokenB;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 _totalSupply = totalSupply();
        amountA = (liquidity * balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amountB = (liquidity * balance1) / _totalSupply; // using balances ensures pro-rata distribution

        require(amountA > 0 && amountB > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY_BURNED");
        approve(msg.sender, liquidity);
        transferFrom(msg.sender, address(this), liquidity);
        _burn(address(this), liquidity);
        _safeTransfer(_token0, msg.sender, amountA);
        _safeTransfer(_token1, msg.sender, amountB);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        reserve0 = balance0;
        reserve1 = balance1;
        emit RemoveLiquidity(msg.sender, amountA, amountB, liquidity);
    }

    function getReserves() external view override returns (uint256 reserveA, uint256 reserveB) {
        reserveA = reserve0;
        reserveB = reserve1;
    }

    function getTokenA() external view override returns (address _tokenA) {
        _tokenA = tokenA;
    }

    function getTokenB() external view override returns (address _tokenB) {
        _tokenB = tokenB;
    }
}
