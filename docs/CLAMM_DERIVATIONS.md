# Concentrated Liquidity AMM (CLAMM) Mathematical Derivations

## 1. Geometric Tick Space and Price Representation

Valence represents prices as square roots in Q64.96 fixed-point notation:

$$\sqrt{P} = \sqrt{\frac{y}{x}} \cdot 2^{96}$$

The tick index $i \in \mathbb{Z}$ discretizes continuous price space via a geometric sequence with ratio $1.0001$:

$$P(i) = 1.0001^i \implies \sqrt{P(i)} = 1.0001^{i / 2}$$

Ticks span the range $[\text{MIN\_TICK}, \text{MAX\_TICK}] = [-887272, 887272]$, corresponding to:
- $\sqrt{P}_{min} = 4295128739$
- $\sqrt{P}_{max} = 1461446703485210103287273052203988822378723970342$

### 1.1 Binary Exponentiation of Square Root Prices (`TickMath.sol`)

Direct evaluation of $1.0001^{i/2}$ on-chain is prohibitively expensive. Valence uses a 20-step binary decomposition of the absolute tick $|i|$:

$$|i| = \sum_{k=0}^{19} b_k 2^k, \quad b_k \in \{0, 1\}$$

Precomputed constants $C_k = 1.0001^{2^{k-1}} \cdot 2^{128}$ allow exact fixed-point reconstruction in 20 bitwise shifts and multiplications. For negative ticks, the ratio is inverted using 256-bit modular arithmetic.

---

## 2. Liquidity and Virtual Reserves

Within an active tick interval $[i_l, i_u]$ with boundary prices $\sqrt{P_a} = \sqrt{P(i_l)}$ and $\sqrt{P_b} = \sqrt{P(i_u)}$, liquidity $L$ defines the depth of the virtual constant product curve:

$$(x + L / \sqrt{P_b})(y + L \sqrt{P_a}) = L^2$$

The relationship between token deltas $\Delta x, \Delta y$ and price change $\Delta \sqrt{P}$ is given by:

$$\Delta x = \Delta\left(\frac{L}{\sqrt{P}}\right) = L \left(\frac{1}{\sqrt{P_{lower}}} - \frac{1}{\sqrt{P_{upper}}}\right) = \frac{L (\sqrt{P_{upper}} - \sqrt{P_{lower}})}{\sqrt{P_{upper}} \sqrt{P_{lower}}}$$

$$\Delta y = \Delta(L \sqrt{P}) = L (\sqrt{P_{upper}} - \sqrt{P_{lower}})$$

---

## 3. Step Swap Computation (`SwapMath.sol`)

During an on-chain swap, execution proceeds through a sequence of steps until the input amount is exhausted or the target price limit is reached.

For a step from current price $\sqrt{P}$ to next tick boundary $\sqrt{P_{target}}$:

### Case 1: Exact Input ($\Delta x$ or $\Delta y$ specified)
If swapping token0 for token1 ($zeroForOne = true$, price decreasing):

$$\Delta x_{max} = \frac{L (\sqrt{P} - \sqrt{P_{target}})}{\sqrt{P} \cdot \sqrt{P_{target}}}$$

If the available input amount $x_{in} \ge \Delta x_{max}$, the price moves all the way to $\sqrt{P_{target}}$, and the tick is crossed. Otherwise, the intermediate price is solved directly:

$$\sqrt{P_{next}} = \frac{L \cdot \sqrt{P}}{L + x_{in} \cdot \sqrt{P}}$$

### Case 2: Exact Output
If a trader specifies an exact output amount $y_{out}$:

$$\sqrt{P_{next}} = \sqrt{P} - \frac{y_{out}}{L}$$

---

## 4. 512-Bit Arithmetic via Hensel Lifting (`FullMath.sol`)

Evaluating $\frac{a \cdot b}{c}$ without phantom overflow when $a \cdot b > 2^{256} - 1$ is accomplished using the Chinese Remainder Theorem and Hensel lifting:

1. Compute product modulo $2^{256}$ using standard EVM multiplication:
   $$prod_0 = a \cdot b \pmod{2^{256}}$$
2. Compute the high 256 bits of the 512-bit product using `mulmod`:
   $$prod_1 = \left\lfloor \frac{a \cdot b}{2^{256}} \right\rfloor = \frac{a \cdot b - \text{mulmod}(a, b, 2^{256})}{2^{256}}$$
3. If $prod_1 = 0$, return standard integer division $prod_0 / c$.
4. If $prod_1 > 0$, compute the modular inverse of $c$ modulo $2^{256}$ via Newton-Raphson iteration (Hensel lifting):
   $$inv_{k+1} = inv_k \cdot (2 - c \cdot inv_k) \pmod{2^{256}}$$
   Starting with $inv_0 = 3 \cdot c \oplus 2$, six iterations yield the exact 256-bit modular inverse.
5. Combine with the high bits to obtain exact quotient without precision loss:
   $$\text{result} = \frac{a \cdot b}{c}$$
