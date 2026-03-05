package recipe

import (
	"errors"
	"sync"
)

// Recipe represents a kitchen recipe
type Recipe struct {
	ID           int      `json:"id"`
	Name         string   `json:"name"`
	Ingredients  []string `json:"ingredients"`
	Instructions string   `json:"instructions"`
}

// Store manages recipes in memory
type Store struct {
	mu      sync.RWMutex
	recipes map[int]Recipe
	nextID  int
}

// NewStore creates a new recipe store
func NewStore() *Store {
	return &Store{
		recipes: make(map[int]Recipe),
		nextID:  1,
	}
}

// Create adds a new recipe
func (s *Store) Create(r Recipe) Recipe {
	s.mu.Lock()
	defer s.mu.Unlock()

	r.ID = s.nextID
	s.recipes[r.ID] = r
	s.nextID++

	return r
}

// Get retrieves a recipe by ID
func (s *Store) Get(id int) (Recipe, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	r, exists := s.recipes[id]
	if !exists {
		return Recipe{}, errors.New("recipe not found")
	}

	return r, nil
}

// GetAll returns all recipes
func (s *Store) GetAll() []Recipe {
	s.mu.RLock()
	defer s.mu.RUnlock()

	recipes := make([]Recipe, 0, len(s.recipes))
	for _, r := range s.recipes {
		recipes = append(recipes, r)
	}

	return recipes
}

// Update modifies an existing recipe
func (s *Store) Update(r Recipe) (Recipe, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.recipes[r.ID]; !exists {
		return Recipe{}, errors.New("recipe not found")
	}

	s.recipes[r.ID] = r
	return r, nil
}

// Delete removes a recipe by ID
func (s *Store) Delete(id int) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.recipes[id]; !exists {
		return errors.New("recipe not found")
	}

	delete(s.recipes, id)
	return nil
}
