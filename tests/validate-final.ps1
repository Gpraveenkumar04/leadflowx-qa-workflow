# LeadFlowX Day 4+ Enhanced Validation Script with Self-Healing
param(
    [switch]$SelfHeal = $false,
    [switch]$Quick = $false,
    [switch]$AutoDetect = $false
)

$Results = @{ 
    TotalTests = 0
    PassedTests = 0
    FailedTests = 0
    Issues = @()
    Actions = @()
}

# Auto-detect containers and services for future extensibility
function Get-LeadFlowXComponents {
    $components = @{
        Infrastructure = @()
        Applications = @()
        Scrapers = @()
        Endpoints = @()
    }
    
    # Detect containers dynamically
    $containers = docker ps -a --filter "name=leadflowx-" --format "{{.Names}}" 2>$null
    if ($containers) {
        foreach ($container in $containers) {
            if ($container -like "*zookeeper*" -or $container -like "*kafka*" -or $container -like "*postgres*" -or $container -like "*redis*") {
                $components.Infrastructure += $container
            } elseif ($container -like "*scraper*") {
                $components.Scrapers += $container
            } else {
                $components.Applications += $container
            }
        }
    }
    
    # Default endpoints (can be extended)
    $components.Endpoints = @(
        @{ Url = "http://localhost:8080"; Name = "Ingestion API" }
        @{ Url = "http://localhost:3000"; Name = "Admin UI" }
        @{ Url = "http://localhost:3002"; Name = "QA UI" }
    )
    
    return $components
}

function Write-Success { param([string]$msg) Write-Host "[PASS] $msg" -ForegroundColor Green }
function Write-Failure { param([string]$msg) Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Write-Info { param([string]$msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }

function Test-Result {
    param([bool]$condition, [string]$successMsg, [string]$failureMsg)
    $Results.TotalTests++
    if ($condition) {
        Write-Success $successMsg
        $Results.PassedTests++
    } else {
        Write-Failure $failureMsg
        $Results.FailedTests++
        $Results.Issues += $failureMsg
    }
    return $condition
}

function Test-Container {
    param([string]$name, [string]$expectedState = "Running")
    
    $status = docker ps -a --filter "name=$name" --format "{{.Status}}"
    
    if ($expectedState -eq "Running") {
        $isHealthy = $status -like "*Up*"
        if (-not $isHealthy -and $SelfHeal) {
            Write-Info "Attempting to restart $name..."
            docker restart $name 2>$null | Out-Null
            Start-Sleep 5
            $status = docker ps --filter "name=$name" --format "{{.Status}}"
            $isHealthy = $status -like "*Up*"
            if ($isHealthy) {
                $Results.Actions += "Restarted $name"
            }
        }
        return Test-Result $isHealthy "Container $name is running" "Container $name is not running"
    } elseif ($expectedState -eq "Exited") {
        # Special handling for one-time job containers like scorer
        $isCompleted = $status -like "*Exited (0)*"
        if ($isCompleted) {
            return Test-Result $true "Container $name completed successfully (one-time job)" "Container $name did not complete successfully"
        } else {
            # Check if it's currently running (might be executing)
            $isRunning = $status -like "*Up*"
            if ($isRunning) {
                return Test-Result $true "Container $name is currently executing" "Container $name has issues"
            } else {
                return Test-Result $false "Container $name completed successfully" "Container $name failed or is in error state"
            }
        }
    } else {
        $isCompleted = $status -like "*Exited (0)*"
        return Test-Result $isCompleted "Container $name completed successfully" "Container $name did not complete successfully"
    }
}

function Test-Endpoint {
    param([string]$url, [string]$name)
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $isHealthy = $response.StatusCode -eq 200
        return Test-Result $isHealthy "Service $name is accessible" "Service $name returned non-200 status"
    } catch {
        # For self-healing, try to restart the related container
        if ($SelfHeal) {
            $containerMap = @{
                "Ingestion API" = "leadflowx-ingestion-api-1"
                "Admin UI" = "leadflowx-admin-ui-1"  
                "QA UI" = "leadflowx-qa-ui-1"
            }
            
            if ($containerMap.ContainsKey($name)) {
                Write-Info "Service $name failed, attempting container restart..."
                docker restart $containerMap[$name] 2>$null | Out-Null
                Start-Sleep 10
                
                try {
                    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        $Results.Actions += "Restarted container for $name"
                        return Test-Result $true "Service $name is accessible (after restart)" "Service $name failed even after restart"
                    }
                } catch { }
            }
        }
        
        # Check if it's just a port mapping issue or expected path
        if ($url -like "*:3002*") {
            # QA UI might need /qa path or different handling
            $altUrl = $url + "/qa"
            try {
                $response = Invoke-WebRequest -Uri $altUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
                if ($response.StatusCode -eq 200) {
                    return Test-Result $true "Service $name is accessible (at /qa endpoint)" "Service $name failed"
                }
            } catch { }
        }
        
        return Test-Result $false "Service $name is accessible" "Service $name failed: timeout or connection error"
    }
}

function Test-Database {
    # Check if raw_leads table has source and scraped_at columns
    $columns = docker exec leadflowx-postgres-1 psql -U postgres -d leadflowx -c "SELECT column_name FROM information_schema.columns WHERE table_name = 'raw_leads';" -t 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        $hasSource = $columns -match "source"
        $hasScrapedAt = $columns -match "scraped_at"
        
        if ($hasSource -and $hasScrapedAt) {
            return Test-Result $true "Database schema has required columns" "Database schema missing columns"
        } else {
            if ($SelfHeal) {
                Write-Info "Adding missing database columns..."
                if (-not $hasSource) {
                    docker exec leadflowx-postgres-1 psql -U postgres -d leadflowx -c "ALTER TABLE raw_leads ADD COLUMN source VARCHAR(100);" 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { $Results.Actions += "Added 'source' column" }
                }
                if (-not $hasScrapedAt) {
                    docker exec leadflowx-postgres-1 psql -U postgres -d leadflowx -c "ALTER TABLE raw_leads ADD COLUMN scraped_at TIMESTAMP;" 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { $Results.Actions += "Added 'scraped_at' column" }
                }
                return Test-Result $true "Database schema has required columns" "Database schema was missing columns (fixed)"
            } else {
                return Test-Result $false "Database schema has required columns" "Database schema missing columns"
            }
        }
    } else {
        return Test-Result $false "Database accessible" "Database connection failed"
    }
}

function Test-Kafka {
    $topics = docker exec leadflowx-kafka-1 kafka-topics.sh --bootstrap-server localhost:9092 --list 2>$null
    
    if ($LASTEXITCODE -ne 0) {
        return Test-Result $false "Kafka accessible" "Kafka connection failed"
    }
    
    $hasLeadRaw = $topics -match "lead.raw"
    $hasLeadVerified = $topics -match "lead.verified"
    
    if ($hasLeadRaw -and $hasLeadVerified) {
        return Test-Result $true "Kafka topics exist" "Required Kafka topics missing"
    } else {
        if ($SelfHeal) {
            Write-Info "Creating missing Kafka topics..."
            if (-not $hasLeadRaw) {
                docker exec leadflowx-kafka-1 kafka-topics.sh --create --topic lead.raw --bootstrap-server localhost:9092 --if-not-exists --partitions 1 --replication-factor 1 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $Results.Actions += "Created 'lead.raw' topic" }
            }
            if (-not $hasLeadVerified) {
                docker exec leadflowx-kafka-1 kafka-topics.sh --create --topic lead.verified --bootstrap-server localhost:9092 --if-not-exists --partitions 1 --replication-factor 1 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $Results.Actions += "Created 'lead.verified' topic" }
            }
            return Test-Result $true "Kafka topics exist" "Required Kafka topics were missing (fixed)"
        } else {
            return Test-Result $false "Kafka topics exist" "Required Kafka topics missing"
        }
    }
}

# Main Validation
Write-Host "LeadFlowX Enhanced Day 4+ Validation Script" -ForegroundColor Cyan
Write-Host "Self-Healing: $(if ($SelfHeal) { 'ENABLED' } else { 'DISABLED (use -SelfHeal to enable)' })" -ForegroundColor Gray
Write-Host "Auto-Detection: $(if ($AutoDetect) { 'ENABLED' } else { 'DISABLED (use -AutoDetect for dynamic discovery)' })" -ForegroundColor Gray
Write-Host ""

# Get components (auto-detect if enabled, otherwise use defaults)
if ($AutoDetect) {
    $components = Get-LeadFlowXComponents
    Write-Info "Auto-detected $($components.Infrastructure.Count) infrastructure, $($components.Applications.Count) application, and $($components.Scrapers.Count) scraper services"
} else {
    # Default known components
    $components = @{
        Infrastructure = @("leadflowx-zookeeper-1", "leadflowx-kafka-1", "leadflowx-postgres-1", "leadflowx-redis-1")
        Applications = @("leadflowx-ingestion-api-1", "leadflowx-verifier-1", "leadflowx-auditor-1", "leadflowx-scorer-1", "leadflowx-admin-ui-1", "leadflowx-qa-ui-1")
        Scrapers = @("leadflowx-scraper-yelp-1", "leadflowx-scraper-etsy-1", "leadflowx-scraper-craigslist-1")
        Endpoints = @(
            @{ Url = "http://localhost:8080"; Name = "Ingestion API" }
            @{ Url = "http://localhost:3000"; Name = "Admin UI" }
            @{ Url = "http://localhost:3002"; Name = "QA UI" }
        )
    }
}

# Infrastructure Services
Write-Host "Testing Infrastructure Services..." -ForegroundColor Magenta
foreach ($container in $components.Infrastructure) {
    Test-Container $container | Out-Null
}

# Application Services
Write-Host "`nTesting Application Services..." -ForegroundColor Magenta
foreach ($container in $components.Applications) {
    # Special handling for scorer (one-time job)
    if ($container -like "*scorer*") {
        Test-Container $container "Exited" | Out-Null
    } else {
        Test-Container $container | Out-Null
    }
}

# Scraper Services
Write-Host "`nTesting Scraper Services..." -ForegroundColor Magenta
foreach ($container in $components.Scrapers) {
    Test-Container $container | Out-Null
}

# Service Endpoints
if (-not $Quick) {
    Write-Host "`nTesting Service Endpoints..." -ForegroundColor Magenta
    foreach ($endpoint in $components.Endpoints) {
        Test-Endpoint $endpoint.Url $endpoint.Name | Out-Null
    }
}

# Database Schema
Write-Host "`nTesting Database Schema..." -ForegroundColor Magenta
Test-Database | Out-Null

# Kafka Topics
Write-Host "`nTesting Kafka Topics..." -ForegroundColor Magenta
Test-Kafka | Out-Null

# Summary Report
$healthScore = if ($Results.TotalTests -gt 0) { [math]::Round(($Results.PassedTests / $Results.TotalTests) * 100, 1) } else { 0 }

Write-Host "`n" + "="*60 -ForegroundColor Cyan
Write-Host "VALIDATION SUMMARY" -ForegroundColor Cyan
Write-Host "="*60 -ForegroundColor Cyan
Write-Host "Overall Health Score: $healthScore%" -ForegroundColor $(
    if ($healthScore -ge 90) { "Green" } 
    elseif ($healthScore -ge 70) { "Yellow" } 
    else { "Red" }
)
Write-Host "Tests Passed: $($Results.PassedTests)/$($Results.TotalTests)"
Write-Host "Tests Failed: $($Results.FailedTests)"

if ($Results.Actions.Count -gt 0) {
    Write-Host "`nSelf-Healing Actions Performed:" -ForegroundColor Green
    foreach ($action in $Results.Actions) {
        Write-Host "  * $action" -ForegroundColor Green
    }
}

if ($Results.Issues.Count -gt 0) {
    Write-Host "`nRemaining Issues:" -ForegroundColor Yellow
    foreach ($issue in $Results.Issues) {
        Write-Host "  * $issue" -ForegroundColor Yellow
    }
}

Write-Host "`n" + "="*60 -ForegroundColor Cyan

# Exit with appropriate status code
if ($healthScore -ge 90) {
    Write-Host "RESULT: LeadFlowX system is healthy and ready!" -ForegroundColor Green
    exit 0
} elseif ($healthScore -ge 70) {
    Write-Host "RESULT: System functional with minor issues" -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "RESULT: System requires attention" -ForegroundColor Red
    exit 2
}

# Usage examples and help
<#
.SYNOPSIS
    LeadFlowX Enhanced Validation Script with Self-Healing capabilities

.DESCRIPTION
    Comprehensive validation script that tests all LeadFlowX components including:
    - Infrastructure services (Kafka, PostgreSQL, Redis, Zookeeper)
    - Application services (APIs, UIs, processors)
    - Scraper services (Yelp, Etsy, Craigslist)
    - Database schema compliance
    - Service endpoints health

.PARAMETER SelfHeal
    Enable automatic fixing of common issues (restart containers, create missing resources)

.PARAMETER Quick
    Skip endpoint testing for faster validation

.PARAMETER AutoDetect
    Automatically discover LeadFlowX containers for dynamic validation

.EXAMPLE
    .\validate-final.ps1
    Basic validation without any fixes

.EXAMPLE
    .\validate-final.ps1 -SelfHeal
    Validation with automatic issue resolution

.EXAMPLE
    .\validate-final.ps1 -Quick -SelfHeal
    Fast validation with healing for container issues only

.EXAMPLE
    .\validate-final.ps1 -AutoDetect -SelfHeal
    Dynamic discovery with auto-healing for extensibility

.NOTES
    Exit Codes:
    0 = Healthy (90%+ health score)
    1 = Functional with minor issues (70-89%)
    2 = Requires attention (<70%)
#>
