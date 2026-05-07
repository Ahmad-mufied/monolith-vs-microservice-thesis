package auth

import "time"

type User struct {
	ID           string
	Name         string
	Email        string
	PasswordHash string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

type UserSummary struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}

func toUserSummary(user User) UserSummary {
	return UserSummary{
		ID:    user.ID,
		Name:  user.Name,
		Email: user.Email,
	}
}
