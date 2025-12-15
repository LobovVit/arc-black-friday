# Задание 10. Миграция на Cassandra: модель данных, стратегии репликации и восстановление целостности

## 1. Контекст

Во время «чёрной пятницы» интернет‑магазин столкнулся с проблемами MongoDB при масштабировании: range‑based шардирование вызывало перераспределение данных при добавлении новых шардов, что приводило к росту latency в пике нагрузки.

**Цель использования Cassandra:**

- высокая отказоустойчивость (leaderless‑репликация);
- быстрое горизонтальное масштабирование без глобального reshuffling;
- равномерное распределение данных;
- высокая скорость записи при экстремальной нагрузке (50 000 RPS+).

⚠️ **Важно:** Cassandra рассматривается **не как замена транзакционной БД**, а как специализированное хранилище для масштабируемых read‑моделей и временных данных.

---

## 2. Какие данные имеет смысл переносить в Cassandra

### Принципиальная архитектурная позиция

> **Cassandra не используется как primary transactional storage для заказов и остатков товаров.**

Создание заказа — транзакционный бизнес‑процесс, требующий атомарности:

```
проверка актуальных остатков → списание остатков → создание заказа
```

Если сервис читает устаревшее состояние остатков, возникает риск **oversell** — продажа товара, которого фактически уже нет в наличии.

Cassandra:
- не поддерживает распределённые транзакции;
- допускает eventual consistency;
- не гарантирует чтение самого актуального состояния данных.

Следовательно, **orders** и **product_stock** не могут быть source of truth в Cassandra.

---

### 2.1 История заказов и события заказов (`order_history`, `order_events`)

- огромный объём данных;
- append‑only характер;
- высокая частота чтений (история пользователя);
- допустима eventual consistency.

✅ **Подходит для Cassandra как read‑model.**

---

### 2.2 Корзины (`carts`)

- очень частые обновления;
- временные данные;
- TTL;
- latency важнее строгой консистентности.

✅ **Идеальный кандидат для Cassandra.**

---

### 2.3 Пользовательские сессии (`sessions`)

- высокий write/read throughput;
- короткий жизненный цикл;
- небольшие рассинхронизации не критичны.

✅ **Подходит для Cassandra.**

---

### 2.4 Товары и остатки (`products`, `product_stock`)

- каталог может кэшироваться;
- остатки участвуют в транзакционном контуре checkout.

❌ **Не подходят для Cassandra как primary storage.**  
⚠️ Допустимо хранение **вспомогательных read‑моделей** (например, для аналитики), но не для принятия бизнес‑решений.

---

### 2.5 Финансовые транзакции и платежи

- строгая консистентность;
- требования ACID.

❌ **Не переносятся в Cassandra.**

---

## 3. Концептуальная модель данных Cassandra

Ключевой принцип Cassandra:

> **Таблица проектируется под конкретный запрос, а не под универсальную модель.**

---

## 3.1 История заказов пользователя (`orders_by_user`)

```sql
CREATE TABLE mobile_store.orders_by_user (
    user_id       uuid,
    year_month    text,
    order_ts      timeuuid,
    order_id      uuid,
    status        text,
    total_amount  decimal,
    geo_zone      text,
    items         list<text>,
    PRIMARY KEY ((user_id, year_month), order_ts)
) WITH CLUSTERING ORDER BY (order_ts DESC);
```

**Назначение:**
- быстрый доступ к истории заказов пользователя;
- UI / личный кабинет;
- аналитические витрины.

---

## 3.2 Поиск заказа по ID (`orders_by_id`)

```sql
CREATE TABLE mobile_store.orders_by_id (
    order_id     uuid,
    user_id      uuid,
    order_ts     timeuuid,
    status       text,
    total_amount decimal,
    items        list<text>,
    PRIMARY KEY (order_id)
);
```

⚠️ Таблица используется **только для чтения**.  
Источник истины остаётся в транзакционной БД.

---

## 3.3 Корзины (`carts`)

```sql
CREATE TABLE mobile_store.carts (
    owner_key   text,
    cart_id     uuid,
    status      text,
    items       map<uuid, int>,
    updated_at  timestamp,
    created_at  timestamp,
    PRIMARY KEY (owner_key)
);
```

---

## 3.4 Сессии (`sessions`)

```sql
CREATE TABLE mobile_store.sessions (
    session_id   uuid,
    user_id      uuid,
    created_at   timestamp,
    last_seen_at timestamp,
    ip           text,
    user_agent   text,
    PRIMARY KEY (session_id)
) WITH default_time_to_live = 86400;
```

---

## 4. Стратегии целостности и согласованности

### Общие механизмы Cassandra
- Hinted Handoff
- Read Repair
- Anti‑Entropy Repair
- Consistency Levels (CL)

---

### 4.1 История заказов (read‑model)

- RF = 3
- write: LOCAL_QUORUM
- read: LOCAL_ONE / LOCAL_QUORUM (по SLA)
- Anti‑Entropy Repair: регулярно

---

### 4.2 Корзины

- RF = 3
- write/read: LOCAL_ONE
- Read Repair: выключен
- Hinted Handoff: включён

---

### 4.3 Сессии

- RF = 3
- write/read: LOCAL_ONE
- TTL минимизирует влияние рассинхронизаций

---

## 5. Архитектурные границы ответственности

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

## Итог

Cassandra используется **строго по назначению**:

- для масштабируемых read‑моделей;
- для временных и высоконагруженных данных;
- без нарушения транзакционных бизнес‑инвариантов.

Решение:
- исключает риск oversell;
- масштабируется горизонтально;
- устойчиво под экстремальной нагрузкой;
- архитектурно корректно и готово к ревью.
