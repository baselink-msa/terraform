# MSK Serverless module

This module creates an optional Amazon MSK Serverless cluster for the event streaming backbone.

It is disabled by default at the dev root module. The first PR can introduce the architecture and IaC shape without creating Kafka resources or cost.

## Design choices

- MSK Serverless is used instead of self-managed Kafka to avoid broker capacity management in the team project.
- IAM authentication is enabled because MSK Serverless requires IAM access control.
- Client traffic uses the IAM broker port `9098`.
- The module only opens the MSK security group from explicitly allowed client security groups.

## Intended use

```text
SQS/Outbox remains the reservation command reliability path.
Kafka becomes the service-wide event streaming and analytics path.
```

Do not route the critical reservation confirmation worker through Kafka in the first phase.
