# SQL Server High Availability on Azure VMs - Automated Deployment

[![Azure](https://img.shields.io/badge/Azure-0078D4?style=for-the-badge&logo=microsoft-azure&logoColor=white)](https://azure.microsoft.com/)
[![SQL Server](https://img.shields.io/badge/SQL%20Server-CC2927?style=for-the-badge&logo=microsoft-sql-server&logoColor=white)](https://www.microsoft.com/en-us/sql-server)
[![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](https://docs.microsoft.com/en-us/powershell/)

A comprehensive automation solution for deploying SQL Server in High Availability configuration on Azure Virtual Machines using Azure CLI. This repository provides production-ready scripts and templates for customer demonstrations and enterprise deployments.

## 🎯 Overview

This project automates the deployment of a complete SQL Server Always On Availability Groups solution on Azure VMs, including:

- **Infrastructure Provisioning**: Automated creation of Azure resources (VMs, networking, storage)
- **Windows Server Failover Cluster**: Automated cluster configuration with cloud witness
- **SQL Server Always On AG**: Complete availability group setup with load balancer
- **Security & Monitoring**: Best practices implementation for enterprise environments
- **Testing & Validation**: Automated testing scripts for deployment verification

## 🏗️ Architecture

The solution deploys the following architecture:

```
┌─────────────────────────────────────────────────────────────┐
│                    Azure Resource Group                     │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────┐                │
│  │   SQL Server    │    │   SQL Server    │                │
│  │   Primary VM    │    │  Secondary VM   │                │
│  │  (Node 1)       │    │   (Node 2)      │                │
│  └─────────────────┘    └─────────────────┘                │
│           │                       │                        │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │        Windows Server Failover Cluster                 │ │
│  │              + Always On AG                            │ │
│  └─────────────────────────────────────────────────────────┘ │
│           │                       │                        │
│  ┌─────────────────┐    ┌─────────────────┐                │
│  │ Azure Load      │    │  File Share     │                │
│  │ Balancer        │    │  Witness VM     │                │
│  └─────────────────┘    └─────────────────┘                │
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │              Virtual Network & Subnets                 │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

### Prerequisites

Before running the deployment scripts, ensure you have:

- **Azure CLI** installed and configured
- **Azure subscription** with appropriate permissions
- **Domain Controller** (existing or will be created)
- **PowerShell 5.1+** or **PowerShell Core 7+**

### Basic Deployment

1. **Clone the repository**:
   ```bash
   git clone https://github.com/ricmmartins/sql-server-ha-azure-demo.git
   cd sql-server-ha-azure-demo
   ```

2. **Configure deployment parameters**:
   ```bash
   cp examples/config-template.json config.json
   # Edit config.json with your specific values
   ```

3. **Run the deployment**:
   ```bash
   ./scripts/automation/deploy-complete-solution.sh
   ```

4. **Verify deployment**:
   ```bash
   ./scripts/testing/test-availability-group.sh
   ```

## 📁 Repository Structure

```
sql-server-ha-azure-demo/
├── README.md                          # This file
├── LICENSE                            # MIT License
├── .gitignore                         # Git ignore rules
├── config.json                        # Deployment configuration
├── scripts/                           # Automation scripts
│   ├── infrastructure/                # Azure infrastructure scripts
│   │   ├── 01-create-resource-group.sh
│   │   ├── 02-create-network.sh
│   │   ├── 03-create-domain-controller.sh
│   │   ├── 04-create-sql-vms.sh
│   │   └── 05-create-load-balancer.sh
│   ├── sql-config/                    # SQL Server configuration
│   │   ├── 01-install-failover-clustering.ps1
│   │   ├── 02-create-wsfc-cluster.ps1
│   │   ├── 03-enable-always-on.ps1
│   │   ├── 04-create-availability-group.ps1
│   │   └── 05-configure-listener.ps1
│   ├── automation/                    # End-to-end automation
│   │   ├── deploy-complete-solution.sh
│   │   ├── cleanup-resources.sh
│   │   └── update-configuration.sh
│   └── testing/                       # Testing and validation
│       ├── test-availability-group.sh
│       ├── test-failover.ps1
│       └── validate-deployment.ps1
├── docs/                              # Documentation
│   ├── deployment-guide.md
│   ├── architecture-overview.md
│   ├── troubleshooting.md
│   └── best-practices.md
├── templates/                         # ARM/Bicep templates
│   ├── main.bicep
│   ├── network.bicep
│   ├── compute.bicep
│   └── parameters.json
└── examples/                          # Example configurations
    ├── config-template.json
    ├── single-subnet-config.json
    └── multi-subnet-config.json
```

## ⚙️ Configuration Options

The deployment supports multiple configuration scenarios:

### Single Subnet Configuration
- Uses Azure Load Balancer for listener connectivity
- Simpler network setup
- Suitable for most scenarios

### Multi Subnet Configuration  
- Eliminates need for load balancer
- Better performance and reliability
- Recommended for production environments

### Availability Options
- **Availability Sets**: 99.95% SLA, lower latency
- **Availability Zones**: 99.99% SLA, higher availability

## 🔧 Customization

### Environment Variables

Key environment variables for customization:

```bash
export AZURE_SUBSCRIPTION_ID="your-subscription-id"
export RESOURCE_GROUP_NAME="sql-ha-demo-rg"
export LOCATION="East US"
export ADMIN_USERNAME="sqladmin"
export DOMAIN_NAME="contoso.local"
export SQL_SERVER_VERSION="SQL2022-WS2022"
```

### Configuration File

Edit `config.json` to customize your deployment:

```json
{
  "subscription": "your-subscription-id",
  "resourceGroup": "sql-ha-demo-rg",
  "location": "East US",
  "vmSize": "Standard_D4s_v3",
  "sqlServerVersion": "SQL2022-WS2022",
  "availabilityOption": "AvailabilityZones",
  "networkConfiguration": "MultiSubnet"
}
```

## 🛡️ Security Features

- **Network Security Groups** with minimal required ports
- **Azure Key Vault** integration for secrets management
- **Managed Identity** for secure Azure resource access
- **Encrypted storage** for SQL Server data and logs
- **Azure Backup** configuration for disaster recovery

## 📊 Monitoring & Alerting

The solution includes:

- **Azure Monitor** integration
- **SQL Server performance counters**
- **Availability group health monitoring**
- **Custom alerts** for failover events
- **Log Analytics** workspace configuration

## 🧪 Testing

Comprehensive testing suite includes:

- **Infrastructure validation**
- **Cluster functionality tests**
- **Availability group failover tests**
- **Performance benchmarking**
- **Disaster recovery scenarios**

Run all tests:
```bash
./scripts/testing/run-all-tests.sh
```

## 📚 Documentation

Detailed documentation is available in the `docs/` directory:

- [Deployment Guide](docs/deployment-guide.md) - Step-by-step deployment instructions
- [Architecture Overview](docs/architecture-overview.md) - Detailed architecture explanation
- [Troubleshooting](docs/troubleshooting.md) - Common issues and solutions
- [Best Practices](docs/best-practices.md) - Production deployment recommendations

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

For support and questions:

- **Issues**: Use GitHub Issues for bug reports and feature requests
- **Discussions**: Use GitHub Discussions for general questions
- **Documentation**: Check the `docs/` directory for detailed guides

## 🏷️ Tags

`azure` `sql-server` `high-availability` `always-on` `availability-groups` `azure-cli` `automation` `infrastructure-as-code` `powershell` `windows-server-failover-cluster`

---



