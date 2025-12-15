#!/usr/bin/env bash
set -euo pipefail

########################################
# Helpers
########################################

log() {
  echo "[$(date '+%H:%M:%S')] $1"
}

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

  docker compose exec -T "$service" mongosh \
    --host localhost \
    --port "$port" \
    --quiet \
    --eval 'rs.status().ok' >/dev/null 2>&1
}

########################################
# Config replica set
########################################

log "=== Config Replica Set ==="
wait_for_mongod configsvr1 27019

if rs_initiated configsvr1 27019; then
  log "configReplSet already initialized"
else
  log "Initializing configReplSet"
  docker compose exec -T configsvr1 mongosh --host localhost --port 27019 --quiet <<'EOF'
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [
    { _id: 0, host: "configsvr1:27019" },
    { _id: 1, host: "configsvr2:27019" },
    { _id: 2, host: "configsvr3:27019" }
  ]
})
EOF
fi

########################################
# Shard 1 replica set
########################################

log "=== Shard1 Replica Set ==="
wait_for_mongod shard1-1 27018

if rs_initiated shard1-1 27018; then
  log "shard1ReplSet already initialized"
else
  docker compose exec -T shard1-1 mongosh --host localhost --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "shard1-1:27018" },
    { _id: 1, host: "shard1-2:27018" },
    { _id: 2, host: "shard1-3:27018" }
  ]
})
EOF
fi

########################################
# Shard 2 replica set
########################################

log "=== Shard2 Replica Set ==="
wait_for_mongod shard2-1 27018

if rs_initiated shard2-1 27018; then
  log "shard2ReplSet already initialized"
else
  docker compose exec -T shard2-1 mongosh --host localhost --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "shard2-1:27018" },
    { _id: 1, host: "shard2-2:27018" },
    { _id: 2, host: "shard2-3:27018" }
  ]
})
EOF
fi

########################################
# Mongos + add shards
########################################

log "=== Mongos ==="
wait_for_mongos

docker compose exec -T mongos mongosh --host localhost --port 27017 --quiet <<'EOF'
try {
  sh.addShard("shard1ReplSet/shard1-1:27018,shard1-2:27018,shard1-3:27018")
} catch (e) { print("shard1 already added") }

try {
  sh.addShard("shard2ReplSet/shard2-1:27018,shard2-2:27018,shard2-3:27018")
} catch (e) { print("shard2 already added") }
EOF

log "=== MongoDB sharding + replication initialized ==="