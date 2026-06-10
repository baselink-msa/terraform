param(
  [string]$AlarmName = "",
  [string]$Namespace = "baselink-dev",
  [string]$DbInstanceIdentifier = "baselink-dev-postgres",
  [string]$ReplicationGroupId = "baselink-dev-redis",
  [string]$SourceQueueName = "ticket-confirm-queue",
  [string]$DeadLetterQueueName = "ticket-confirm-dlq",
  [int]$LookbackMinutes = 30
)

$ErrorActionPreference = "Continue"

function Write-Section {
  param([string]$Title)
  Write-Host ""
  Write-Host "==== $Title ===="
}

function Invoke-CheckedCommand {
  param(
    [string]$Label,
    [scriptblock]$Command
  )

  Write-Section $Label
  try {
    & $Command
  } catch {
    Write-Host "Failed: $($_.Exception.Message)"
  }
}

$endTime = (Get-Date).ToUniversalTime().ToString("s")
$startTime = (Get-Date).AddMinutes(-1 * $LookbackMinutes).ToUniversalTime().ToString("s")

Write-Host "Data alarm diagnosis"
Write-Host "AlarmName=$AlarmName"
Write-Host "Namespace=$Namespace"
Write-Host "LookbackMinutes=$LookbackMinutes"
Write-Host "StartTimeUtc=$startTime"
Write-Host "EndTimeUtc=$endTime"

Invoke-CheckedCommand "CloudWatch alarm state" {
  if ($AlarmName -eq "") {
    Write-Host "AlarmName was not provided. Skipping exact alarm lookup."
  } else {
    aws cloudwatch describe-alarms `
      --alarm-names $AlarmName `
      --query "MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason,Updated:StateUpdatedTimestamp}" `
      --output table
  }
}

Invoke-CheckedCommand "RDS instance summary" {
  aws rds describe-db-instances `
    --db-instance-identifier $DbInstanceIdentifier `
    --query "DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,Class:DBInstanceClass,BackupRetentionPeriod:BackupRetentionPeriod,LatestRestorableTime:LatestRestorableTime,PendingModifiedValues:PendingModifiedValues}" `
    --output table
}

Invoke-CheckedCommand "RDS CPUUtilization" {
  aws cloudwatch get-metric-statistics `
    --namespace AWS/RDS `
    --metric-name CPUUtilization `
    --dimensions Name=DBInstanceIdentifier,Value=$DbInstanceIdentifier `
    --start-time $startTime `
    --end-time $endTime `
    --period 300 `
    --statistics Average,Maximum `
    --query "Datapoints[].{Time:Timestamp,Avg:Average,Max:Maximum}" `
    --output table
}

Invoke-CheckedCommand "RDS DatabaseConnections" {
  aws cloudwatch get-metric-statistics `
    --namespace AWS/RDS `
    --metric-name DatabaseConnections `
    --dimensions Name=DBInstanceIdentifier,Value=$DbInstanceIdentifier `
    --start-time $startTime `
    --end-time $endTime `
    --period 300 `
    --statistics Average,Maximum `
    --query "Datapoints[].{Time:Timestamp,Avg:Average,Max:Maximum}" `
    --output table
}

Invoke-CheckedCommand "RDS FreeableMemory and FreeStorageSpace" {
  aws cloudwatch get-metric-statistics `
    --namespace AWS/RDS `
    --metric-name FreeableMemory `
    --dimensions Name=DBInstanceIdentifier,Value=$DbInstanceIdentifier `
    --start-time $startTime `
    --end-time $endTime `
    --period 300 `
    --statistics Minimum `
    --query "Datapoints[].{Time:Timestamp,MinBytes:Minimum}" `
    --output table

  aws cloudwatch get-metric-statistics `
    --namespace AWS/RDS `
    --metric-name FreeStorageSpace `
    --dimensions Name=DBInstanceIdentifier,Value=$DbInstanceIdentifier `
    --start-time $startTime `
    --end-time $endTime `
    --period 300 `
    --statistics Minimum `
    --query "Datapoints[].{Time:Timestamp,MinBytes:Minimum}" `
    --output table
}

Invoke-CheckedCommand "Valkey replication group" {
  aws elasticache describe-replication-groups `
    --replication-group-id $ReplicationGroupId `
    --query "ReplicationGroups[0].{Status:Status,Engine:Engine,AutomaticFailover:AutomaticFailover,MultiAZ:MultiAZ,Members:NodeGroups[0].NodeGroupMembers[].{ClusterId:CacheClusterId,Role:CurrentRole,AZ:PreferredAvailabilityZone}}" `
    --output json
}

Invoke-CheckedCommand "SQS source queue attributes" {
  $queueUrl = aws sqs get-queue-url `
    --queue-name $SourceQueueName `
    --query QueueUrl `
    --output text

  aws sqs get-queue-attributes `
    --queue-url $queueUrl `
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage `
    --output table
}

Invoke-CheckedCommand "SQS DLQ attributes" {
  $dlqUrl = aws sqs get-queue-url `
    --queue-name $DeadLetterQueueName `
    --query QueueUrl `
    --output text

  aws sqs get-queue-attributes `
    --queue-url $dlqUrl `
    --attribute-names ApproximateNumberOfMessages ApproximateAgeOfOldestMessage `
    --output table
}

Invoke-CheckedCommand "Kubernetes workload state" {
  kubectl get pods -n $Namespace
  kubectl get hpa -n $Namespace
  kubectl get scaledobject -n $Namespace
}

Invoke-CheckedCommand "Recent ticket-worker logs" {
  kubectl logs -n $Namespace deploy/ticket-worker-service --tail=80
}

Invoke-CheckedCommand "Recent ticket-service logs" {
  kubectl logs -n $Namespace deploy/ticket-service --tail=80
}

Write-Section "Operator notes"
Write-Host "1. If RDS CPU and DatabaseConnections are both high, check connection pool and traffic spike first."
Write-Host "2. If SQS backlog is high but worker pods are healthy, compare worker concurrency and DB write errors."
Write-Host "3. If DLQ has messages, inspect and fix the root cause before redrive."
Write-Host "4. If Valkey evictions occurred, check TTL/key growth before increasing capacity."
Write-Host "5. Paste this output into the AI diagnosis prompt in docs/ops-alarm-runbook.md."
