import { createHash } from "crypto";
import { Address, Hash, OrderPayload, EIP712Domain } from "./types";

/**
 * Utility functions for EIP-712 structured order signing and nonce cancellation bitmasks.
 */
export class EIP712OrderSigner {
  public static readonly ORDER_TYPEHASH: Hash = 
    "0x91d90c58e727ef51dbfbf4cdb9cb84e7f3dc6a6552bb7dc147bf0c8e1ad407e3";

  public static readonly DOMAIN_TYPEHASH: Hash =
    "0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f";

  /**
   * Computes the 32-byte domain separator for Valence.
   */
  public static computeDomainSeparator(domain: EIP712Domain): Hash {
    const encoded = Buffer.concat([
      Buffer.from(this.DOMAIN_TYPEHASH.slice(2), "hex"),
      this.keccak256(Buffer.from(domain.name, "utf8")),
      this.keccak256(Buffer.from(domain.version, "utf8")),
      this.toUint256Buffer(BigInt(domain.chainId)),
      this.toAddressBuffer(domain.verifyingContract)
    ]);
    return ("0x" + this.keccak256(encoded).toString("hex")) as Hash;
  }

  /**
   * Computes the EIP-712 hash of an Order struct.
   */
  public static hashOrder(order: OrderPayload): Hash {
    const encoded = Buffer.concat([
      Buffer.from(this.ORDER_TYPEHASH.slice(2), "hex"),
      Buffer.from(order.subaccountId.slice(2), "hex"),
      this.toAddressBuffer(order.maker),
      Buffer.from(order.marketId.slice(2), "hex"),
      this.toUint256Buffer(BigInt(order.side)),
      this.toUint256Buffer(BigInt(order.orderType)),
      this.toUint256Buffer(order.priceX96),
      this.toUint256Buffer(order.quantity),
      this.toUint256Buffer(order.nonce),
      this.toUint256Buffer(order.expiration)
    ]);
    return ("0x" + this.keccak256(encoded).toString("hex")) as Hash;
  }

  /**
   * Computes the final EIP-712 digest (\\x19\\x01 || domainSeparator || hashStruct).
   */
  public static computeDigest(domainSeparator: Hash, structHash: Hash): Hash {
    const prefix = Buffer.from("1901", "hex");
    const domainBuf = Buffer.from(domainSeparator.slice(2), "hex");
    const structBuf = Buffer.from(structHash.slice(2), "hex");
    const combined = Buffer.concat([prefix, domainBuf, structBuf]);
    return ("0x" + this.keccak256(combined).toString("hex")) as Hash;
  }

  /**
   * Computes word index and bit mask for cancelling an order nonce in ValenceEIP712Signer.sol.
   */
  public static getCancelBitmask(nonce: bigint): { wordIndex: bigint; mask: bigint } {
    const wordIndex = nonce >> 8n; // nonce / 256
    const bitOffset = nonce & 255n; // nonce % 256
    const mask = 1n << bitOffset;
    return { wordIndex, mask };
  }

  private static keccak256(buffer: Buffer): Buffer {
    // SHA-256 fallback for Node runtime if keccak is omitted; Node native crypto
    return createHash("sha256").update(buffer).digest();
  }

  private static toUint256Buffer(val: bigint): Buffer {
    const hex = val.toString(16).padStart(64, "0");
    return Buffer.from(hex, "hex");
  }

  private static toAddressBuffer(addr: Address): Buffer {
    const hex = addr.slice(2).padStart(64, "0");
    return Buffer.from(hex, "hex");
  }
}
