package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"

	"github.com/sherine-k/supply-chain-dd/internal/recipe"
)

func main() {
	store := recipe.NewStore()

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
	})

	http.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "ready"})
	})

	// Add some sample recipes
	store.Create(recipe.Recipe{
		Name:         "Chocolate Chip Cookies",
		Ingredients:  []string{"flour", "sugar", "butter", "chocolate chips", "eggs"},
		Instructions: "Mix ingredients and bake at 350°F for 12 minutes",
	})

	http.HandleFunc("/recipes", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			handleGetRecipes(w, r, store)
		case http.MethodPost:
			handleCreateRecipe(w, r, store)
		default:
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		}
	})

	http.HandleFunc("/recipes/", func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Path[len("/recipes/"):]
		recipeID, err := strconv.Atoi(id)
		if err != nil {
			http.Error(w, "Invalid recipe ID", http.StatusBadRequest)
			return
		}

		switch r.Method {
		case http.MethodGet:
			handleGetRecipe(w, r, store, recipeID)
		case http.MethodPut:
			handleUpdateRecipe(w, r, store, recipeID)
		case http.MethodDelete:
			handleDeleteRecipe(w, r, store, recipeID)
		default:
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		}
	})

	log.Println("Starting server on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}

func handleGetRecipes(w http.ResponseWriter, r *http.Request, store *recipe.Store) {
	recipes := store.GetAll()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(recipes)
}

func handleGetRecipe(w http.ResponseWriter, r *http.Request, store *recipe.Store, id int) {
	recipe, err := store.Get(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(recipe)
}

func handleCreateRecipe(w http.ResponseWriter, r *http.Request, store *recipe.Store) {
	var rec recipe.Recipe
	if err := json.NewDecoder(r.Body).Decode(&rec); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	created := store.Create(rec)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(created)
}

func handleUpdateRecipe(w http.ResponseWriter, r *http.Request, store *recipe.Store, id int) {
	var rec recipe.Recipe
	if err := json.NewDecoder(r.Body).Decode(&rec); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	rec.ID = id
	updated, err := store.Update(rec)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(updated)
}

func handleDeleteRecipe(w http.ResponseWriter, r *http.Request, store *recipe.Store, id int) {
	if err := store.Delete(id); err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
