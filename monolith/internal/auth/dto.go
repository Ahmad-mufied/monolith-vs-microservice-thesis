package auth

type RegisterRequest struct {
	Name     string `json:"name" validate:"required,max=120"`
	Email    string `json:"email" validate:"required"`
	Password string `json:"password" validate:"required,min=8,max=72"`
}

type LoginRequest struct {
	Email    string `json:"email" validate:"required"`
	Password string `json:"password" validate:"required,min=8,max=72"`
}

type RegisterResponse struct {
	Message string               `json:"message"`
	Data    RegisterResponseData `json:"data"`
}

type RegisterResponseData struct {
	User UserSummary `json:"user"`
}

type LoginResponse struct {
	Message string            `json:"message"`
	Data    LoginResponseData `json:"data"`
}

type LoginResponseData struct {
	Token string      `json:"token"`
	User  UserSummary `json:"user"`
}
