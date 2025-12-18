# Microsoft MCP Servers

## Overview

This repository contains Microsoft's Model Context Protocol (MCP) servers that provide AI agents with structured access to Azure, Microsoft Fabric, and other Microsoft services. MCP is an open protocol that standardizes how applications provide context to large language models (LLMs).

## Repository Structure

```
├── core/                           # Core libraries and shared components
│   ├── Azure.Mcp.Core/            # Azure MCP core library
│   ├── Microsoft.Mcp.Core/        # Base MCP protocol implementation
│   ├── Microsoft.Fabric.Mcp.Core/ # Fabric-specific core library
│   └── Template.Mcp.Core/         # Template for new MCP cores
├── servers/                        # Individual MCP servers
│   ├── Azure.Mcp.Server/          # Azure MCP server (40+ Azure services)
│   ├── Fabric.Mcp.Server/         # Microsoft Fabric MCP server
│   └── Template.Mcp.Server/       # Template for new MCP servers
├── tools/                          # Service-specific toolset implementations
│   ├── Azure.Mcp.Tools.Storage/   # Azure Storage operations
│   ├── Azure.Mcp.Tools.KeyVault/  # Azure Key Vault operations
│   ├── Azure.Mcp.Tools.Sql/       # Azure SQL operations
│   └── [40+ other Azure services] # Individual service toolsets
├── eng/                           # Engineering system and build infrastructure
│   ├── scripts/                   # Build, test, and deployment scripts
│   ├── pipelines/                 # Azure DevOps pipeline definitions
│   └── tools/                     # Development and validation tools
└── docs/                          # Documentation and implementation guides
```

## Key Components

| Component | Description |
|-----------|-------------|
| **Azure MCP Server** | Complete Azure service integration with 100+ tools across 40+ services |
| **Microsoft Fabric MCP Server** | Fabric workspace and data platform operations |
| **Core Libraries** | Shared infrastructure for command patterns, authentication, and MCP protocol |
| **Toolsets** | Individual Azure service implementations (Storage, SQL, KeyVault, etc.) |

## Supported Azure Services

The Azure MCP Server includes tools for:

- **Storage**: Blob, Table, Queue, File storage operations
- **Compute**: App Service, Function Apps, AKS, Virtual Desktop
- **Data**: Cosmos DB, SQL, PostgreSQL, MySQL, Kusto
- **Security**: Key Vault, Authorization, Confidential Ledger
- **Messaging**: Service Bus, Event Hubs, Event Grid, SignalR
- **AI/ML**: Application Insights, Monitor, Speech
- **DevOps**: ACR, Deploy, Load Testing
- And many more...

## Quick Start

### Prerequisites

- .NET SDK 10.0.100-preview.7+
- Node.js 20+
- PowerShell 7.0+
- Azure CLI (for authentication)

### Build

```powershell
# Clone and build
git clone https://github.com/microsoft/mcp.git
cd mcp
dotnet build

# Verify build
./eng/scripts/Build-Local.ps1 -UsePaths -VerifyNpx
```

### Run Tests

```powershell
# Run all unit tests
./eng/scripts/Test-Code.ps1

# Run tests for specific toolset
./eng/scripts/Test-Code.ps1 -Paths Storage
```

## Development Guidelines

### Coding Standards

- Use primary constructors for all C# classes
- Use `System.Text.Json` over Newtonsoft.Json
- Make command classes `sealed` unless designed for inheritance
- All code must be AOT (Ahead-of-Time) compilation safe
- Put each class and interface in separate files

### Command Naming Convention

Commands follow the pattern: `azmcp <service> <resource> <operation>`

```bash
azmcp storage account get          # Get storage accounts
azmcp sql database show            # Show SQL database details
azmcp keyvault secret get          # Get Key Vault secret
```

### Parameter Naming

- Use `subscription` (never `subscriptionId`)
- Use `resourceGroup` (not `resourceGroupName`)
- Use singular nouns for resource names (e.g., `server`, not `serverName`)

## Documentation

- [Azure MCP Server README](servers/Azure.Mcp.Server/README.md)
- [Fabric MCP Server README](servers/Fabric.Mcp.Server/README.md)
- [Contributing Guidelines](CONTRIBUTING.md)
- [New Command Implementation Guide](docs/new-command.md)

## Links

- [Official MCP Website](https://modelcontextprotocol.io)
- [Azure MCP Documentation](https://learn.microsoft.com/azure/developer/azure-mcp-server/)
- [GitHub Repository](https://github.com/microsoft/mcp)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
