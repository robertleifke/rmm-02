## RMM-02


Minimal monolithic smart contract that is an AMM using the RMM trading function.

## Setup

Requires forge to be installed already.

```
forge install
```

## Testing

```
forge test -vvv
```

## Coverage

```
forge coverage --report lcov
cmd + shift + p -> Coverage Gutters: Display Coverage
```

## Gas benchmarks

### View gas usage

```
forge snapshot --gas-report
```

### Compare gas usage
```
forge snapshot --diff
```
