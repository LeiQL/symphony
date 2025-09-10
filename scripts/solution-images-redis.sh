#!/bin/bash
# Script to create and populate a Redis hash with solution image names

# Redis connection details - use environment variables or defaults
REDIS_HOST=${REDIS_HOST:-"localhost"}
REDIS_PORT=${REDIS_PORT:-6379}
REDIS_PASSWORD=${REDIS_PASSWORD:-""}
REDIS_PROTOCOL=${REDIS_PROTOCOL:-"redis"}  # redis or rediss (for TLS)

# Table (hash) name - customize as needed
HASH_NAME=${HASH_NAME:-"solution_registry"}

# Authentication parameter
AUTH_PARAM=""
if [ -n "$REDIS_PASSWORD" ]; then
  AUTH_PARAM="-a $REDIS_PASSWORD"
fi

# TLS parameter
TLS_PARAM=""
if [ "$REDIS_PROTOCOL" = "rediss" ]; then
  TLS_PARAM="--tls"
fi

echo "============================================"
echo "Redis Solutions Registry Creator"
echo "============================================"
echo "Connecting to Redis at $REDIS_HOST:$REDIS_PORT"

# Check if Redis CLI is installed
if ! command -v redis-cli &> /dev/null; then
  echo "Error: redis-cli is not installed or not in PATH"
  exit 1
fi

# Check if Redis is reachable
redis-cli -h $REDIS_HOST -p $REDIS_PORT $AUTH_PARAM $TLS_PARAM PING > /dev/null
if [ $? -ne 0 ]; then
  echo "Error: Cannot connect to Redis at $REDIS_HOST:$REDIS_PORT"
  echo "Please check your Redis connection settings"
  exit 1
fi

echo "Successfully connected to Redis"

# Check if the hash already exists
EXISTS=$(redis-cli -h $REDIS_HOST -p $REDIS_PORT $AUTH_PARAM $TLS_PARAM EXISTS $HASH_NAME)
if [ "$EXISTS" -eq 1 ]; then
  echo "Hash '$HASH_NAME' already exists."
  
  # Option to clear existing hash
  read -p "Do you want to delete the existing hash? (y/n): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    redis-cli -h $REDIS_HOST -p $REDIS_PORT $AUTH_PARAM $TLS_PARAM DEL $HASH_NAME > /dev/null
    echo "Removed existing hash with the name '$HASH_NAME'"
  else
    echo "Will add/update fields in the existing hash."
  fi
fi

# Create and populate the hash with the imageName array and other fields
echo "Adding solution images to hash '$HASH_NAME' in Redis..."

# The JSON array of solution images - properly escaped for bash
IMAGE_NAMES_JSON='["solutiona", "solutionb", "solutionc"]'

# Adding the imageName field with the JSON array
redis-cli -h $REDIS_HOST -p $REDIS_PORT $AUTH_PARAM $TLS_PARAM HSET $HASH_NAME \
  "imageName" "$IMAGE_NAMES_JSON" \
  "lastUpdated" "$(date +%s)" \
  "registry" "symphony" \
  "description" "List of available solution images"

# Verify the hash was created by retrieving all fields and values
echo -e "\nHash updated. Contents:"
redis-cli -h $REDIS_HOST -p $REDIS_PORT $AUTH_PARAM $TLS_PARAM HGETALL $HASH_NAME

# Display the imageName field specifically
echo -e "\nVerifying imageName field:"
IMAGE_NAMES=$(redis-cli -h $REDIS_HOST -p $REDIS_PORT $AUTH_PARAM $TLS_PARAM HGET $HASH_NAME imageName)
echo "imageName: $IMAGE_NAMES"

echo -e "\nHash update complete!"
echo "============================================"
