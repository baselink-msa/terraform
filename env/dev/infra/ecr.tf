module "ecr" {
  source = "../../../modules/ecr"

  environment = "dev"
  
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