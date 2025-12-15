#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $1"; }

wait_for_mongod() {
  local service=$1
  local port=$2
  until docker compose exec -T "$service" mongosh --host localhost --port "$port" --quiet --eval 'db.runCommand({ ping: 1 })' >/dev/null 2>&1
  do
    log "⏳ Waiting for mongod on $service:$port..."
    sleep 2
  done
  log "✅ mongod ready on $service:$port"
}

wait_for_mongos() {
  until docker compose exec -T mongos mongosh --host localhost --port 27017 --quiet --eval 'sh.status()' >/dev/null 2>&1
  do
    log "⏳ Waiting for mongos to accept sh.status()..."
    sleep 2
  done
  log "✅ mongos is ready"
}

rs_initiated() {
  local service=$1
  local port=$2
  docker compose exec -T "$service" mongosh --host localhost --port "$port" --quiet --eval 'rs.status().ok' >/dev/null 2>&1
}

init_single_node_rs() {
  local service=$1
  local port=$2
  local rsname=$3
  local hostport=$4

  if rs_initiated "$service" "$port"; then
    log "$rsname already initialized"
  else
    log "Initializing $rsname (single-node)"
    docker compose exec -T "$service" mongosh --host localhost --port "$port" --quiet <<EOF
rs.initiate({
  _id: "$rsname",
  members: [
    { _id: 0, host: "$hostport" }
  ]
})
EOF
  fi
}

log "=== Config Server (CSRS single-node) ==="
wait_for_mongod configsvr 27019
init_single_node_rs configsvr 27019 configReplSet "configsvr:27019"

log "=== Shard1 (single-node RS) ==="
wait_for_mongod shard1 27018
init_single_node_rs shard1 27018 shard1ReplSet "shard1:27018"

log "=== Shard2 (single-node RS) ==="
wait_for_mongod shard2 27018
init_single_node_rs shard2 27018 shard2ReplSet "shard2:27018"

log "=== Mongos ==="
wait_for_mongos

log "=== Enable sharding & add shards ==="
docker compose exec -T mongos mongosh --host localhost --port 27017 --quiet <<'EOF'
try { sh.enableSharding("somedb") } catch (e) { print("sharding already enabled") }

try { sh.addShard("shard1ReplSet/shard1:27018") } catch (e) { print("shard1 already added") }
try { sh.addShard("shard2ReplSet/shard2:27018") } catch (e) { print("shard2 already added") }

use somedb

try { db.createCollection("helloDoc") } catch (e) {}

db.helloDoc.createIndex({ _id: "hashed" })

try { sh.shardCollection("somedb.helloDoc", { _id: "hashed" }) } catch (e) { print("collection already sharded") }
EOF

log "=== MongoDB sharding initialized (Task2: single-node RS for config + shards) ==="
