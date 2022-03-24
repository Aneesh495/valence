import { Address, Hash, OrderSide, OrderType, AccountRiskProfile } from "./types";

export interface ValenceClientConfig {
  clearinghouseAddress: Address;
  vaultAddress: Address;
  orderBookAddress: Address;
  routerAddress: Address;
  oracleRelayAddress: Address;
  portfolioMarginAddress: Address;
  chainId: number;
}

/**
 * Institutional client interface for the Valence Decentralized Clearinghouse.
 */
export class ValenceClient {
  public readonly config: ValenceClientConfig;

  constructor(config: ValenceClientConfig) {
    this.config = config;
  }

  /**
   * Generates calldata payload for depositing collateral into ValenceVault.
   */
  public encodeDeposit(subaccountId: Hash, asset: Address, amount: bigint): {
    to: Address;
    data: Hash;
  } {
    // Function selector for deposit(bytes32,address,uint256): 0x47e7ef24
    const selector = "0x47e7ef24";
    const subaccountHex = subaccountId.slice(2).padStart(64, "0");
    const assetHex = asset.slice(2).padStart(64, "0");
    const amountHex = amount.toString(16).padStart(64, "0");
    const data = `${selector}${subaccountHex}${assetHex}${amountHex}` as Hash;

    return {
      to: this.config.vaultAddress,
      data
    };
  }

  /**
   * Generates calldata payload for withdrawing collateral from ValenceVault.
   */
  public encodeWithdraw(subaccountId: Hash, asset: Address, amount: bigint, recipient: Address): {
    to: Address;
    data: Hash;
  } {
    // Function selector for withdraw(bytes32,address,uint256,address): 0x69328dec
    const selector = "0x69328dec";
    const subaccountHex = subaccountId.slice(2).padStart(64, "0");
    const assetHex = asset.slice(2).padStart(64, "0");
    const amountHex = amount.toString(16).padStart(64, "0");
    const recipientHex = recipient.slice(2).padStart(64, "0");
    const data = `${selector}${subaccountHex}${assetHex}${amountHex}${recipientHex}` as Hash;

    return {
      to: this.config.vaultAddress,
      data
    };
  }

  /**
   * Generates calldata payload for placing a limit order into ValenceOrderBook.
   */
  public encodePlaceOrder(
    subaccountId: Hash,
    marketId: Hash,
    side: OrderSide,
    orderType: OrderType,
    priceX96: bigint,
    quantity: bigint
  ): {
    to: Address;
    data: Hash;
  } {
    // Function selector for placeOrder(bytes32,bytes32,uint8,uint8,uint256,uint256): 0xd0230c00
    const selector = "0xd0230c00";
    const subHex = subaccountId.slice(2).padStart(64, "0");
    const marketHex = marketId.slice(2).padStart(64, "0");
    const sideHex = side.toString(16).padStart(64, "0");
    const typeHex = orderType.toString(16).padStart(64, "0");
    const priceHex = priceX96.toString(16).padStart(64, "0");
    const qtyHex = quantity.toString(16).padStart(64, "0");
    const data = `${selector}${subHex}${marketHex}${sideHex}${typeHex}${priceHex}${qtyHex}` as Hash;

    return {
      to: this.config.orderBookAddress,
      data
    };
  }

  /**
   * Generates calldata payload for executing a market/perpetual trade on ValenceClearinghouse.
   */
  public encodeExecuteTrade(
    subaccountId: Hash,
    marketId: Hash,
    sizeDelta: bigint,
    acceptablePriceX96: bigint
  ): {
    to: Address;
    data: Hash;
  } {
    // Function selector for executeTrade(bytes32,bytes32,int256,uint256): 0x7599cb51
    const selector = "0x7599cb51";
    const subHex = subaccountId.slice(2).padStart(64, "0");
    const marketHex = marketId.slice(2).padStart(64, "0");
    
    // Two's complement representation for int256
    let deltaBig = sizeDelta;
    if (deltaBig < 0n) {
      deltaBig = (1n << 256n) + deltaBig;
    }
    const deltaHex = deltaBig.toString(16).padStart(64, "0");
    const priceHex = acceptablePriceX96.toString(16).padStart(64, "0");
    const data = `${selector}${subHex}${marketHex}${deltaHex}${priceHex}` as Hash;

    return {
      to: this.config.clearinghouseAddress,
      data
    };
  }
}
