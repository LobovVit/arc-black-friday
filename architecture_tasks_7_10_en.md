# Architectural Report: MongoDB & Cassandra — Tasks 7–10

## Table of Contents
1. Introduction  
2. Task 7 — MongoDB Data Modeling & Sharding Keys  
   - 2.1 Collection Schemas  
   - 2.2 Shard Key Choices  
   - 2.3 Example MongoDB Sharding Commands  
   - 2.4 ASCII Diagrams  
3. Task 8 — Hot Shard Detection & Mitigation  
   - 3.1 Metrics  
   - 3.2 Diagnostic Queries  
   - 3.3 Balancing & Resharding Strategies  
   - 3.4 ASCII Diagrams  
4. Task 9 — Read Preferences & Consistency  
   - 4.1 Primary vs Secondary Read Matrix  
   - 4.2 Acceptable Lag  
   - 4.3 Example Configurations  
5. Task 10 — Cassandra Migration Architecture  
   - 5.1 What to Migrate & Why  
   - 5.2 Cassandra Data Models  
   - 5.3 Partition Keys & Hot Partition Prevention  
   - 5.4 Consistency & Repair Strategies  
   - 5.5 ASCII Diagrams  
6. Summary  

---

# 1. Introduction

This architectural document consolidates tasks **7–10**, covering:

- MongoDB collection modeling  
- Sharding strategy  
- Hot shard detection and mitigation  
- Read preference consistency rules  
- Migration of high‑load entities to Cassandra  

The document uses ASCII diagrams for clarity and contains full rationale, examples, metrical recommendations, and schema definitions.

---

# 2. Task 7 — MongoDB Data Modeling & Sharding Keys

## 2.1 Collection Schemas

### **Collection: products**

```
{
  "_id": ObjectId,
  "name": String,
  "category": String,
  "price": Number,
  "stock": {
    "<geo_zone>": Number
  },
  "attributes": {
    "color": String,
    "size": String
  }
}
```

### **Collection: orders**

```
{
  "_id": UUID,
  "user_id": UUID,
  "created_at": Date,
  "items": [
    { "product_id": UUID, "price": Number, "qty": Number }
  ],
  "status": "new" | "paid" | "shipped" | "delivered",
  "total": Number,
  "geo_zone": String
}
```

### **Collection: carts**

```
{
  "_id": UUID,
  "user_id": UUID,
  "session_id": String,
  "items": [
    { "product_id": UUID, "quantity": Number }
  ],
  "status": "active" | "ordered" | "abandoned",
  "created_at": Date,
  "updated_at": Date,
  "expires_at": Date
}
```

---

## 2.2 Shard Key Choices

### **products**

**Shard key:**
```
{ category: "hashed", _id: 1 }
```

**Rationale:**

- Most catalog queries are filtered by `category`.
- Using `hashed(category)` allows `mongos` to route category queries to a limited subset of shards instead of performing scatter‑gather across the entire cluster.
- `_id` as a second component ensures even distribution of documents inside a single category.

---

### **orders**

**Shard key:**
```
{ user_id: 1, created_at: 1 }
```

**Pros:**

- users scan their own orders  
- prevents enormous partitions by adding time component  

---

### **carts**

**Derived key `owner_key`:**

```
owner_key = "user:<id>" OR "session:<id>"
```

**Shard key:**
```
{ owner_key: "hashed" }
```

**Rationale:**

- massive cardinality, perfect distribution  
- each cart fits a single partition  

---

## 2.3 Example MongoDB Sharding Commands

### Products

```
sh.shardCollection("shop.products", { category: "hashed", _id: 1 })
```

### Orders

```
sh.shardCollection("shop.orders", { user_id: 1, created_at: 1 });
```

### Carts

```
sh.shardCollection("shop.carts", { owner_key: "hashed" });
```

---

## 2.4 ASCII Diagram — MongoDB Cluster (Sharded)

```
                   +----------------+
                   |   mongos       |
                   +--------+-------+
                            |
                 -------------------------
                 |                       |
        +--------v--------+     +--------v--------+
        |   Shard 1       |     |    Shard 2      |
        |  (RS: 1-1,1-2)  |     |  (RS: 2-1,2-2)   |
        +--------+--------+     +--------+--------+
                 |                       |
                 -------------------------
                            |
                    +-------v-------+
                    | Config Server |
                    +---------------+
```

---

# 3. Task 8 — Hot Shard Detection & Mitigation

## 3.1 Metrics to Monitor

| Metric | Purpose |
|--------|---------|
| CPU per shard | Detect overloaded nodes |
| Disk IOPS | Identify I/O hotspots |
| Network throughput | Identify skewed traffic |
| Chunk count per shard | Detect uneven data distribution |
| Collection size per shard | Direct indicator of imbalance |
| Query latency distribution | Detect slow shards |
| Ops/sec by operation type | Understand load profile |

---

## 3.2 Diagnostic Commands

### Check chunk distribution:

```
use config
db.chunks.aggregate([
  { $match: { ns: "shop.products" }},
  { $group: { _id: "$shard", cnt: { $sum: 1 }}}
])
```

### Storage statistics:

```
db.products.aggregate([{ $collStats: { storageStats: {} } }])
```

---

## 3.3 Mitigation Strategies

### **1. Resharding**

```
db.adminCommand({
  reshardCollection: "shop.products",
  key: { category: 1, _id: "hashed" }
});
```

### **2. Manual split**

```
sh.splitAt("shop.products",
  { category: "electronics", price: 500 }
)
```

### **3. Move chunks**

```
sh.moveChunk("shop.products",
    { category: "electronics", price: 500 },
    "shard02"
)
```

### **4. Zonal sharding**

Useful if categories intentionally grouped.

---

## 3.4 ASCII Diagram — Hot Shard Scenario

```
          +-----------+
          |  Shard 1  |  <--- HOT (70% of "electronics")
          +-----------+
                ^
                |
   uneven distribution due to range-based shard key
                |
          +-----------+
          |  Shard 2  |
          +-----------+
```

After resharding (hashed sub‑key):

```
   electronics items --> evenly distributed across all shards
```

---

# 4. Task 9 — Read Preferences & Consistency

## 4.1 Primary vs Secondary Read Matrix

| Collection | Operation | Read Target | Reason |
|------------|-----------|-------------|--------|
| products | catalog browsing | **secondary** | eventual OK |
| products | add to cart | primaryPreferred | verify price/stock |
| products | final checkout | **primary** | strict consistency |
| orders | history | secondaryPreferred | stale OK |
| orders | payment | **primary** | critical data |
| carts | read current | **primary** | must be fresh |
| carts | TTL cleanup | secondary | not user-facing |

---

## 4.2 Acceptable Replication Lag

| Operation | Lag |
|----------|------|
| catalog browsing | 3–10s |
| order history | 3–5s |
| stock pre-check | 1–2s |
| checkout & payments | 0s |
| carts operations | 0s |

---

## 4.3 Minimal Example Configuration (Python)

```
MongoClient(
    uri,
    readPreference="secondaryPreferred"
)
```

For strict ops:

```
MongoClient(
    uri,
    readPreference="primary"
)
```

---

# 5. Task 10 — Cassandra Migration: Correct Scope and Boundaries

## 5.1 Key Architectural Position

Cassandra is NOT used as a primary transactional storage for orders or product stock.

Order creation is a transactional business process requiring atomicity:

check stock → decrement stock → create order

If a service reads stale stock data, a critical business risk arises: oversell.

Cassandra:
- does not support distributed transactions;
- allows eventual consistency;
- does not guarantee reading the latest state.

Therefore, orders and product_stock cannot be the source of truth in Cassandra.

---

## 5.2 What Is Migrated to Cassandra

| Data | Migrated |
|-----|----------|
| carts | YES |
| sessions | YES |
| order history (read-model) | YES |
| orders (primary) | NO |
| product stock (primary) | NO |

The source of truth for orders and stock remains in a transactional database.

---

## 5.3 Cassandra as Read-Model and Temporary Storage

### carts
```
CREATE TABLE carts (
    owner_key text,
    cart_id uuid,
    status text,
    items map<uuid,int>,
    updated_at timestamp,
    PRIMARY KEY(owner_key)
);
```

### sessions
```
CREATE TABLE sessions (
    session_id uuid,
    user_id uuid,
    created_at timestamp,
    last_seen timestamp,
    PRIMARY KEY(session_id)
) WITH default_time_to_live = 86400;
```

### order_history_by_user
```
CREATE TABLE order_history_by_user (
    user_id uuid,
    year_month text,
    order_ts timeuuid,
    order_id uuid,
    status text,
    total decimal,
    PRIMARY KEY ((user_id, year_month), order_ts)
);
```

---

## 5.4 Architectural Responsibility Boundaries

```
┌─────────────────────────────┐
│ Transactional DB            │
│ orders + product_stock      │  ← source of truth
└─────────────┬───────────────┘
              │ domain events
              ▼
┌─────────────────────────────┐
│ Cassandra                   │
│ carts, sessions, history    │
└─────────────────────────────┘
```

---

# 6. Summary

The proposed architecture:
- preserves strict consistency in the transactional core;
- scales read-models and temporary data horizontally;
- eliminates oversell risk;
- applies Cassandra correctly and safely without violating business invariants.
