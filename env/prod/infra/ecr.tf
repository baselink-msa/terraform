module "ecr" {
  source = "../../../modules/ecr"

  environment = "prod"
  
  repositories = [
    "auth-service",
    "game-service",
    "waiting-room-service",
    "seat-lock-service",
    "ticket-service",
    "ticket-worker-service",
    "order-service",
    "ai-chatbot-service",
    "admin-service"
  ]
}