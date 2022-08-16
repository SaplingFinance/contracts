# Solidity API

## IVerificationHub

### ban

```solidity
function ban(address party) external
```

### unban

```solidity
function unban(address party) external
```

### verify

```solidity
function verify(address party) external
```

### unverify

```solidity
function unverify(address party) external
```

### registerSaplingPool

```solidity
function registerSaplingPool(address pool) external
```

### isBadActor

```solidity
function isBadActor(address party) external view returns (bool)
```

### isVerified

```solidity
function isVerified(address party) external view returns (bool)
```

### isSaplingPool

```solidity
function isSaplingPool(address party) external view returns (bool)
```
