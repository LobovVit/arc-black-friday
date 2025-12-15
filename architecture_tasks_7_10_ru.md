# Архитектурный отчёт: MongoDB и Cassandra — Задания 7–10

## Оглавление
1. Введение  
2. Задание 7 — Архитектура данных MongoDB и выбор shard‑ключей  
   - 2.1 Структуры коллекций  
   - 2.2 Выбор shard‑ключей  
   - 2.3 Примеры команд шардирования MongoDB  
   - 2.4 ASCII‑диаграммы  
3. Задание 8 — Обнаружение «горячих» шардов и устранение дисбаланса  
   - 3.1 Метрики  
   - 3.2 Диагностические запросы  
   - 3.3 Стратегии устранения дисбаланса  
   - 3.4 ASCII‑диаграммы  
4. Задание 9 — Настройки чтения с реплик и консистентность  
   - 4.1 Матрица операций Primary/Secondary  
   - 4.2 Допустимые задержки  
   - 4.3 Примеры конфигураций  
5. Задание 10 — Архитектура миграции в Cassandra  
   - 5.1 Какие данные переносить и почему  
   - 5.2 Модели данных Cassandra  
   - 5.3 Partition‑ключи и предотвращение горячих партиций  
   - 5.4 Стратегии согласованности и восстановления  
   - 5.5 ASCII‑диаграммы  
6. Итоговое резюме  

---

# 1. Введение

Этот документ объединяет результаты заданий **7–10**, посвящённых:

- проектированию коллекций MongoDB,
- выбору оптимальных shard‑ключей,
- обнаружению и устранению «горячих» шардов,
- настройке консистентности при чтении,
- миграции высоконагруженных данных в Cassandra,
- проектированию моделей данных для горизонтального масштабирования.

Все диаграммы представлены в виде **ASCII-схем**, чтобы максимально упростить восприятие.

---

# 2. Задание 7 — Архитектура данных MongoDB и выбор shard‑ключей

## 2.1 Структуры коллекций

### Коллекция `products`
```
{
  "_id": ObjectId,
  "name": String,
  "category": String,
  "price": Number,
  "stock": { "<geo_zone>": Number },
  "attributes": { "color": String, "size": String }
}
```

### Коллекция `orders`
```
{
  "_id": UUID,
  "user_id": UUID,
  "created_at": Date,
  "items": [
    { "product_id": UUID, "price": Number, "qty": Number }
  ],
  "status": "new"|"paid"|"shipped"|"delivered",
  "total": Number,
  "geo_zone": String
}
```

### Коллекция `carts`
```
{
  "_id": UUID,
  "user_id": UUID,
  "session_id": String,
  "items": [
    { "product_id": UUID, "quantity": Number }
  ],
  "status": "active"|"ordered"|"abandoned",
  "created_at": Date,
  "updated_at": Date,
  "expires_at": Date
}
```

---

## 2.2 Выбор shard‑ключей

### `products`
Shard‑key:
```
{ category: "hashed", _id: 1 }
```

**Преимущества:**
- Основные запросы каталога фильтруются по `category`.
- Использование `hashed(category)` позволяет `mongos` **таргетировать запросы по категории** и избежать scatter‑gather по всем шардам.
- Второй компонент `_id` обеспечивает равномерное распределение документов внутри категории.

---

### `orders`
Shard‑key:
```
{ user_id: 1, created_at: 1 }
```

Позволяет эффективно получать историю заказов пользователя, не создавая гигантских партиций.

---

### `carts`
Используется derived key:
```
owner_key = "user:<id>" или "session:<id>"
```

Shard‑key:
```
{ owner_key: "hashed" }
```

Гарантирует равномерное распределение нагрузки по множеству пользователей и сессий.

---

## 2.3 Примеры команд MongoDB

```
sh.shardCollection("shop.products", { category: "hashed", _id: 1 })
sh.shardCollection("shop.orders", { user_id: 1, created_at: 1 });
sh.shardCollection("shop.carts", { owner_key: "hashed" });
```

---

## 2.4 ASCII‑диаграмма шардированного кластера MongoDB

```
                   +----------------+
                   |     mongos     |
                   +--------+-------+
                            |
                 -------------------------
                 |                       |
        +--------v--------+     +--------v--------+
        |   Shard 1       |     |    Shard 2      |
        |  (RS: 1-1,1-2)  |     |  (RS: 2-1,2-2)  |
        +--------+--------+     +--------+--------+
                 |                       |
                 -------------------------
                            |
                    +-------v-------+
                    | Config Server |
                    +---------------+
```

---

# 3. Задание 8 — Горячие шарды: Метрики и устранение

## 3.1 Метрики

| Метрика | Назначение |
|--------|------------|
| CPU per shard | понять перегруженную ноду |
| Disk IOPS | выявить дисковые узкие места |
| Network throughput | трафиковые аномалии |
| Chunk count | дисбаланс шардов |
| Объём данных per shard | прямой индикатор смещения |
| Latency | рост задержек |
| Ops/sec | тип нагрузки |

---

## 3.2 Диагностические запросы

### Распределение чанков:

```
use config
db.chunks.aggregate([
  { $match: { ns: "shop.products" }},
  { $group: { _id: "$shard", count: { $sum: 1 }}}
])
```

### Статистика коллекции:

```
db.products.aggregate([{ $collStats: { storageStats: {} } }])
```

---

## 3.3 Методы устранения

### Resharding
```
db.adminCommand({
  reshardCollection: "shop.products",
  key: { category: 1, _id: "hashed" }
})
```

### split
```
sh.splitAt("shop.products", { category: "electronics", price: 500 })
```

### moveChunk
```
sh.moveChunk("shop.products",
    { category: "electronics", price: 500 },
    "shard02"
)
```

---

## 3.4 ASCII‑диаграмма «горячего» шарда

```
          +-----------+
          |  Shard 1  |  <--- HOT (70% запросов "electronics")
          +-----------+
                ^
                |
   неравномерное распределение из-за range shard key
                |
          +-----------+
          |  Shard 2  |
          +-----------+
```

После применения hashed‑ключа:

```
electronics -> распределены равномерно по всем шардам
```

---

# 4. Задание 9 — Чтение с реплик и консистентность

## 4.1 Матрица чтений

| Коллекция | Операция | Target | Причина |
|-----------|----------|--------|---------|
| products | просмотр каталога | secondary | eventual OK |
| products | добавление в корзину | primaryPreferred | уточнение цен |
| products | checkout | primary | строгая консистентность |
| orders | история | secondaryPreferred | допускается лаг |
| orders | оплата | primary | критичность |
| carts | текущая корзина | primary | не допускается рассинхрон |
| carts | TTL‑очистка | secondary | не влияет на UX |

---

## 4.2 Допустимый лаг

| Операция | Лаг |
|----------|------|
| каталог | 3–10s |
| история заказов | 3–5s |
| проверка остатков | 1–2s |
| checkout | 0s |
| корзины | 0s |

---

## 4.3 Пример конфигурации клиента

```
MongoClient(uri, readPreference="secondaryPreferred")
MongoClient(uri, readPreference="primary")
```

---

# 5. Задание 10 — Миграция на Cassandra: корректные границы применения

## 5.1 Ключевая архитектурная позиция

> **Cassandra не используется как primary transactional storage для заказов и остатков товаров.**

Создание заказа является транзакционным бизнес-процессом и требует атомарности:

```
проверка актуальных остатков → списание остатков → создание заказа
```

Если сервис читает устаревшее состояние остатков, возникает критический риск **oversell** — продажа отсутствующего товара.

Cassandra:
- не поддерживает распределённые транзакции;
- допускает eventual consistency;
- не гарантирует чтение последнего состояния данных.

---

## 5.2 Что переносится в Cassandra

| Данные | Перенос |
|------|---------|
| carts | ✅ |
| sessions | ✅ |
| история заказов (read-model) | ✅ |
| заказы (primary) | ❌ |
| остатки (primary) | ❌ |

Источник истины для заказов и остатков остаётся в **транзакционной БД**.

---

## 5.3 Cassandra как read-model и storage временных данных

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

## 5.4 Архитектурные границы ответственности

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

# 6. Итоговое резюме

Архитектура обеспечивает:
- строгую консистентность в транзакционном контуре;
- масштабируемость и отказоустойчивость read-моделей;
- отсутствие риска oversell;
- корректное применение Cassandra без нарушения бизнес-инвариантов.
