# Recipe API

A simple REST API for managing kitchen recipes.

## Running the Application

```bash
go run cmd/recipe-api/main.go
```

The server will start on `http://localhost:8080`

## API Endpoints

### Health Check
```bash
curl http://localhost:8080/health
```

### Readiness Check
```bash
curl http://localhost:8080/ready
```

### Get All Recipes
```bash
curl http://localhost:8080/recipes
```

### Get a Single Recipe
```bash
curl http://localhost:8080/recipes/1
```

### Create a Recipe
```bash
curl -X POST http://localhost:8080/recipes \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Pancakes",
    "ingredients": ["flour", "eggs", "milk", "butter"],
    "instructions": "Mix all ingredients and cook on griddle"
  }'
```

### Update a Recipe
```bash
curl -X PUT http://localhost:8080/recipes/1 \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Updated Pancakes",
    "ingredients": ["flour", "eggs", "milk", "butter", "vanilla"],
    "instructions": "Mix all ingredients, add vanilla, and cook on griddle"
  }'
```

### Delete a Recipe
```bash
curl -X DELETE http://localhost:8080/recipes/1
```

## Recipe Model

```json
{
  "id": 1,
  "name": "Recipe Name",
  "ingredients": ["ingredient1", "ingredient2"],
  "instructions": "Step by step instructions"
}
```

## Features

- In-memory storage (data persists only while the application is running)
- Thread-safe operations using sync.RWMutex
- Standard library only (no external dependencies)
- RESTful API design
- JSON request/response format
