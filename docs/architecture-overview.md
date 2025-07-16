# SQL Server High Availability on Azure - Architecture Overview

**Author:** Manus AI  
**Version:** 1.0.0  
**Last Updated:** January 2025

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Principles](#architecture-principles)
3. [Component Architecture](#component-architecture)
4. [Network Architecture](#network-architecture)
5. [Security Architecture](#security-architecture)
6. [High Availability Design](#high-availability-design)
7. [Performance Considerations](#performance-considerations)
8. [Scalability and Growth](#scalability-and-growth)
9. [Disaster Recovery](#disaster-recovery)
10. [Cost Analysis](#cost-analysis)
11. [References](#references)

## Executive Summary

The SQL Server High Availability architecture on Microsoft Azure represents a comprehensive enterprise-grade solution designed to provide maximum uptime, data protection, and performance for mission-critical database workloads. This architecture leverages Azure's cloud infrastructure capabilities combined with SQL Server Always On Availability Groups to deliver a robust, scalable, and cost-effective high availability solution.

The solution addresses key business requirements including 99.9% availability targets, automatic failover capabilities, read-scale scenarios, and comprehensive disaster recovery options. By implementing Windows Server Failover Clustering (WSFC) as the foundation and SQL Server Always On Availability Groups as the database-level high availability mechanism, the architecture provides both infrastructure resilience and application-level fault tolerance.

### Key Architectural Benefits

The architecture delivers significant advantages over traditional on-premises high availability solutions through cloud-native integration and modern high availability technologies. Primary benefits include reduced infrastructure complexity through managed Azure services, improved scalability through cloud resource elasticity, and enhanced disaster recovery capabilities through Azure's global infrastructure.

Cost optimization opportunities emerge through right-sizing capabilities, reserved instance pricing, and operational efficiency improvements enabled by automation and monitoring integration. The architecture supports both development and production scenarios with appropriate scaling and cost management strategies.

Operational benefits include simplified management through Azure Portal integration, comprehensive monitoring through Azure Monitor, and automated backup capabilities through Azure Blob Storage integration. These capabilities reduce administrative overhead while improving system reliability and compliance posture.

## Architecture Principles

The SQL Server HA architecture follows established design principles that ensure reliability, security, performance, and maintainability. These principles guide architectural decisions and provide a framework for evaluating design alternatives and implementation approaches.

### High Availability Principles

High availability design prioritizes system uptime through redundancy, fault tolerance, and rapid recovery mechanisms. The architecture implements multiple layers of redundancy including infrastructure redundancy through Azure Availability Zones, application redundancy through SQL Server Always On, and data redundancy through synchronous replication.

Fault tolerance mechanisms ensure that single points of failure are eliminated or mitigated through appropriate redundancy and failover capabilities. The design includes automatic failure detection, rapid failover execution, and transparent recovery for client applications.

Recovery time objectives (RTO) and recovery point objectives (RPO) drive architectural decisions regarding synchronization modes, backup strategies, and failover mechanisms. The architecture supports RTO targets of less than 2 minutes and RPO targets of zero for synchronous replicas.

### Security Principles

Security design implements defense-in-depth strategies with multiple security layers protecting against various threat vectors. The architecture includes network security through virtual network isolation and security groups, identity security through Active Directory integration, and data security through encryption and access controls.

Principle of least privilege governs access control implementation with service accounts, administrative permissions, and application access configured with minimal necessary permissions. Regular access reviews and audit logging ensure ongoing compliance with security policies.

Data protection mechanisms include encryption at rest through Azure disk encryption and SQL Server TDE, encryption in transit through SSL/TLS protocols, and backup encryption for data protection during storage and transfer operations.

### Performance Principles

Performance design optimizes system responsiveness and throughput through appropriate resource sizing, storage configuration, and network optimization. The architecture implements SQL Server best practices for storage layout, memory configuration, and query optimization.

Storage performance optimization includes separate disk configurations for data files, transaction logs, and backup storage with appropriate caching and performance tier selection. Premium SSD storage provides consistent performance characteristics required for production database workloads.

Network performance optimization includes appropriate virtual machine sizing for network bandwidth requirements, load balancer configuration for optimal connection distribution, and network security group rules that minimize latency while maintaining security.

### Scalability Principles

Scalability design enables system growth through both vertical and horizontal scaling approaches. The architecture supports vertical scaling through virtual machine resizing and horizontal scaling through read replica addition and workload distribution.

Resource elasticity enables dynamic scaling based on workload requirements with appropriate monitoring and automation to manage scaling operations. Azure's cloud infrastructure provides the foundation for elastic scaling capabilities.

Growth planning considerations include capacity monitoring, performance trending, and proactive scaling to accommodate business growth and changing workload characteristics. The architecture supports both planned growth and unexpected demand spikes.

## Component Architecture

The component architecture defines the individual system components, their relationships, and their roles within the overall high availability solution. Each component serves specific functions while integrating with other components to provide comprehensive high availability capabilities.

### Virtual Machine Infrastructure

Virtual machine infrastructure provides the compute foundation for all system components including SQL Server instances, domain controllers, and supporting services. The infrastructure implements Azure best practices for availability, performance, and security.

SQL Server virtual machines utilize compute-optimized or memory-optimized instance families to provide appropriate CPU and memory resources for database workloads. Default configurations use Standard_E4s_v3 instances with 4 vCPUs and 32 GB RAM, providing balanced performance for most workloads while maintaining cost efficiency.

Domain controller virtual machines provide Active Directory services with appropriate sizing for the expected number of domain members and authentication requests. Standard_D2s_v3 instances provide adequate resources for domain controller operations while minimizing costs.

Witness server virtual machines provide quorum services for Windows Server Failover Clustering with minimal resource requirements. Standard_B2s instances provide cost-effective compute resources for witness server operations.

Availability configuration supports both Availability Sets and Availability Zones depending on regional capabilities and requirements. Availability Zones provide enhanced resilience through physical separation of infrastructure components across multiple data centers within an Azure region.

### Storage Architecture

Storage architecture implements SQL Server best practices with separate storage configurations for different file types and performance requirements. The design optimizes performance, reliability, and cost through appropriate storage tier selection and configuration.

Data file storage utilizes Premium SSD disks with read/write caching enabled to provide optimal performance for database read and write operations. P30 (1 TB) disks provide 5,000 IOPS and 200 MB/s throughput suitable for most database workloads.

Transaction log storage utilizes Premium SSD disks with write caching disabled to ensure transaction durability and optimal log write performance. P20 (512 GB) disks provide 2,300 IOPS and 150 MB/s throughput appropriate for transaction log requirements.

Backup storage implements a hybrid approach with local Premium SSD storage for immediate backup and recovery operations and Azure Blob Storage for long-term retention and disaster recovery. This approach balances performance requirements with cost optimization.

Temporary database storage utilizes local SSD storage when available to provide optimal performance for temporary database operations. Local SSD storage provides the highest performance characteristics for temporary workloads while reducing costs.

### Network Infrastructure

Network infrastructure provides secure, high-performance connectivity between system components while enabling client access and administrative management. The design implements Azure networking best practices for security, performance, and reliability.

Virtual network configuration creates isolated network environments with appropriate address space allocation and subnet segmentation. The default configuration uses 10.0.0.0/16 address space with /24 subnets for different server roles.

Load balancer configuration provides high availability for client connections through health monitoring and automatic failover capabilities. Internal load balancers distribute connections to available SQL Server replicas based on Always On availability group status.

Network security groups implement security controls at the subnet and network interface levels with rules configured to allow necessary communication while blocking unauthorized access. Default rules permit Active Directory, SQL Server, and cluster communication while restricting external access.

DNS configuration integrates with Active Directory to provide name resolution for cluster members and Always On listeners. Custom DNS settings ensure proper name resolution throughout the virtual network environment.

## Network Architecture

Network architecture provides the connectivity foundation for all system components while implementing security controls and performance optimization. The design balances security requirements with performance needs and operational simplicity.

### Virtual Network Design

Virtual network design creates isolated network environments with appropriate segmentation and security controls. The design implements hub-and-spoke patterns where appropriate while maintaining simplicity for single-region deployments.

Address space allocation provides adequate capacity for current deployment requirements and future growth. The default 10.0.0.0/16 allocation provides over 65,000 IP addresses with subnet allocations that support hundreds of servers per subnet.

Subnet design separates different server roles to enable granular security controls and traffic management. Dedicated subnets for domain controllers, SQL Server nodes, and witness servers simplify security group configuration and network troubleshooting.

Route table configuration ensures optimal traffic flow between subnets and external networks. Default routing configurations support standard communication patterns while enabling custom routing for specific requirements.

### Security Group Configuration

Network security group configuration implements security controls at multiple network layers with rules designed to permit necessary communication while blocking unauthorized access. The configuration follows principle of least privilege with specific rules for required communication patterns.

Inbound rules permit necessary communication including Active Directory services (ports 53, 88, 135, 389, 445, 464, 636, 3268, 3269), SQL Server communication (port 1433), and cluster communication (various dynamic ports). Administrative access rules permit RDP and WinRM connections from authorized networks.

Outbound rules generally permit all outbound communication while specific restrictions may be implemented based on organizational security policies. Outbound rules ensure that servers can access required services including Windows Update, Azure services, and external dependencies.

Application security groups provide additional granular control by grouping servers with similar security requirements. This approach simplifies rule management and enables more precise security controls based on server roles and functions.

### Load Balancer Integration

Load balancer integration provides high availability for client connections while supporting SQL Server Always On requirements. The configuration includes health monitoring, connection distribution, and failover detection capabilities.

Frontend IP configuration defines the listener IP address that clients use to connect to the availability group. This IP address remains consistent during failover operations, providing transparent failover for client applications.

Backend pool configuration includes all SQL Server nodes as potential targets for client connections. The load balancer automatically manages pool membership based on health probe results and availability group status.

Health probe configuration uses TCP probes on a dedicated port to monitor availability group status. Probe settings include appropriate timeout and retry values to balance responsiveness with stability during failover scenarios.

Load balancing rules define how connections are distributed among available backend pool members. Rules are configured for SQL Server Always On requirements including session persistence and floating IP support.

## Security Architecture

Security architecture implements comprehensive protection mechanisms across all system layers including network security, identity management, data protection, and access controls. The design follows defense-in-depth principles with multiple security layers providing overlapping protection.

### Identity and Access Management

Identity and access management provides centralized authentication and authorization services through Active Directory integration. The design implements secure service account management, administrative access controls, and audit logging capabilities.

Active Directory integration provides the security foundation for all system components with centralized user and computer account management. Domain functional levels are configured to support modern authentication protocols and security features.

Service account management implements dedicated accounts for each service with complex passwords, appropriate group memberships, and specific service principal names (SPNs) for Kerberos authentication. Service accounts follow principle of least privilege with minimal necessary permissions.

Administrative access controls include role-based access controls for different administrative functions, multi-factor authentication requirements for privileged operations, and just-in-time access mechanisms for enhanced security.

Audit logging captures security-relevant events including authentication attempts, privilege escalation, and administrative operations. Log retention and analysis procedures ensure that security events are properly monitored and investigated.

### Data Protection

Data protection mechanisms ensure that sensitive information remains secure both at rest and in transit. Implementation includes multiple encryption layers, access controls, and backup protection to prevent unauthorized access and ensure data integrity.

Encryption at rest includes Azure disk encryption for virtual machine disks and SQL Server Transparent Data Encryption (TDE) for database files. Key management procedures ensure secure key storage, rotation, and access controls.

Encryption in transit includes SSL/TLS encryption for all network communications including client connections, replication traffic, and administrative access. Certificate management procedures ensure proper certificate deployment and renewal.

Backup protection includes encryption of backup files both during transfer and storage operations. Backup access controls ensure that backup files are protected against unauthorized access while remaining available for legitimate recovery operations.

Database-level security includes column-level encryption for sensitive data, row-level security for multi-tenant scenarios, and dynamic data masking for development and testing environments. These features provide granular data protection based on specific requirements.

### Network Security

Network security implements multiple layers of protection including virtual network isolation, security group controls, and traffic monitoring. The design prevents unauthorized access while enabling necessary communication between system components.

Virtual network isolation provides the foundation for network security by creating isolated network environments that are separate from other Azure resources and external networks. Network peering and gateway connections are configured only when specifically required.

Security group controls implement firewall-like functionality at the subnet and network interface levels. Rules are configured to permit only necessary communication while blocking all other traffic by default.

Network monitoring includes traffic analysis, intrusion detection, and security event logging to identify potential security threats and policy violations. Monitoring integration with Azure Security Center provides centralized security management and alerting.

Micro-segmentation strategies may be implemented for enhanced security in high-security environments. These strategies include additional subnet segmentation, application security groups, and network virtual appliances for advanced threat protection.

## High Availability Design

High availability design ensures maximum system uptime through redundancy, fault tolerance, and rapid recovery mechanisms. The architecture implements multiple layers of high availability protection from infrastructure through application levels.

### Clustering Architecture

Windows Server Failover Clustering provides the foundation for high availability through cluster resource management, health monitoring, and coordinated failover operations. The clustering architecture is optimized for Azure environments with appropriate timeout values and network configurations.

Cluster quorum configuration ensures proper cluster behavior during various failure scenarios including node failures, network partitions, and storage issues. The design supports both file share witness and cloud witness configurations with cloud witness recommended for production deployments.

Cluster networking configuration optimizes communication between cluster nodes with appropriate heartbeat intervals, timeout values, and routing configurations. Network settings are tuned for Azure virtual network environments to ensure reliable cluster operation.

Resource management includes cluster-aware resources for SQL Server services, availability groups, and supporting components. Resource dependencies and failover policies are configured to ensure proper startup order and failover behavior.

### Always On Availability Groups

SQL Server Always On Availability Groups provide database-level high availability with automatic failover capabilities, read-scale scenarios, and flexible backup options. The configuration supports both synchronous and asynchronous replication based on requirements.

Primary replica configuration hosts the read-write copy of databases and coordinates synchronization with secondary replicas. Primary replica settings include automatic failover partners, backup preferences, and connection routing configurations.

Secondary replica configuration includes synchronization mode settings, backup preferences, and read-only access configuration. Secondary replicas can be configured for automatic failover, manual failover, or read-only scenarios based on requirements.

Listener configuration provides a consistent connection endpoint for client applications with automatic connection redirection during failover scenarios. Listener settings include IP address configuration, port settings, and read-only routing rules.

Synchronization monitoring ensures that data replication between replicas operates within acceptable parameters. Monitoring includes synchronization state, data latency, and queue size metrics to ensure proper Always On operation.

### Failover Mechanisms

Failover mechanisms provide automatic and manual failover capabilities with appropriate detection, decision, and execution processes. The design ensures rapid failover with minimal data loss and service disruption.

Automatic failover detection includes health monitoring at multiple levels including SQL Server service health, database availability, and network connectivity. Detection mechanisms are tuned to balance responsiveness with stability to prevent unnecessary failovers.

Failover execution includes coordinated shutdown of services on failed nodes, resource movement to surviving nodes, and service startup on target nodes. Execution procedures are optimized for minimal downtime and proper service initialization.

Client connection recovery includes automatic connection redirection through Always On listeners and connection retry logic in client applications. Recovery mechanisms ensure that client applications can reconnect quickly after failover operations.

Failback procedures enable returning services to preferred nodes after recovery from failure conditions. Failback operations are typically performed during maintenance windows to minimize service disruption.

## Performance Considerations

Performance considerations ensure that the high availability architecture delivers optimal database performance while maintaining availability and reliability characteristics. The design implements SQL Server best practices and Azure optimization techniques.

### Storage Performance

Storage performance optimization includes appropriate disk configurations, caching settings, and performance tier selection to meet database performance requirements. The design implements SQL Server storage best practices for optimal performance.

Data file performance utilizes Premium SSD storage with read/write caching enabled to provide optimal performance for database read and write operations. Disk sizing is based on IOPS and throughput requirements for expected workloads.

Transaction log performance utilizes Premium SSD storage with write caching disabled to ensure transaction durability and optimal log write performance. Log disk configuration prioritizes write performance and consistency over read performance.

Backup performance includes dedicated storage for backup operations to prevent interference with production database operations. Backup storage configuration balances performance requirements with cost considerations.

Storage monitoring includes performance counter collection, latency measurement, and throughput analysis to ensure that storage performance meets requirements and identify optimization opportunities.

### Compute Performance

Compute performance optimization includes appropriate virtual machine sizing, CPU configuration, and memory allocation to support database workloads effectively. The design balances performance requirements with cost considerations.

Virtual machine sizing follows SQL Server best practices with compute-optimized or memory-optimized instance families selected based on workload characteristics. Instance sizing considers CPU requirements, memory needs, and network performance requirements.

Memory configuration implements SQL Server best practices with appropriate buffer pool sizing, leaving adequate memory for operating system operations while maximizing SQL Server memory allocation. Memory settings are tuned based on database size and concurrent user requirements.

CPU configuration includes appropriate core counts and processor features to support database operations effectively. Hyper-threading and NUMA configuration are considered for optimal performance on multi-core systems.

Performance monitoring includes CPU utilization, memory usage, and wait statistics analysis to identify performance bottlenecks and optimization opportunities. Monitoring data guides capacity planning and performance tuning activities.

### Network Performance

Network performance optimization ensures adequate bandwidth and low latency for database operations, replication traffic, and client connectivity. The design implements Azure networking best practices for optimal performance.

Virtual machine network performance scales with instance size, requiring appropriate VM sizing for network-intensive workloads. Network performance considerations include both bandwidth and packet-per-second capabilities.

Load balancer performance includes connection distribution algorithms, health probe configurations, and session persistence settings optimized for SQL Server Always On requirements. Load balancer settings balance performance with high availability requirements.

Replication network performance includes bandwidth allocation for Always On synchronization traffic and network optimization for minimal latency between replicas. Network configuration prioritizes replication traffic to ensure data consistency.

Client connectivity performance includes connection pooling recommendations, connection string optimization, and network path optimization for client applications. Performance optimization reduces connection overhead and improves application responsiveness.

## Scalability and Growth

Scalability design enables system growth through both vertical and horizontal scaling approaches while maintaining high availability characteristics. The architecture supports planned growth and unexpected demand increases through cloud elasticity.

### Vertical Scaling

Vertical scaling enables increasing system capacity through virtual machine resizing, storage expansion, and performance tier upgrades. The design supports online scaling operations where possible to minimize service disruption.

Virtual machine scaling includes CPU and memory upgrades through Azure virtual machine resizing operations. Scaling procedures include appropriate planning, testing, and execution steps to ensure successful scaling operations.

Storage scaling includes disk size increases and performance tier upgrades to accommodate growing database sizes and performance requirements. Storage scaling operations are designed to minimize downtime and maintain data integrity.

Performance scaling includes optimization of SQL Server configurations, index maintenance, and query optimization to improve system performance without hardware changes. Performance scaling provides cost-effective capacity improvements.

### Horizontal Scaling

Horizontal scaling enables capacity increases through additional replica deployment, read-scale scenarios, and workload distribution. The design supports adding secondary replicas for both high availability and read-scale scenarios.

Read replica scaling includes deploying additional secondary replicas configured for read-only access to support reporting and analytics workloads. Read replicas can be deployed in the same region or different regions based on requirements.

Geographic scaling includes deploying replicas in multiple Azure regions for disaster recovery and global read-scale scenarios. Geographic scaling requires additional network configuration and synchronization planning.

Workload distribution includes implementing read-only routing to distribute read workloads across secondary replicas while maintaining write operations on the primary replica. Distribution strategies optimize resource utilization and improve overall system performance.

### Capacity Planning

Capacity planning ensures that system resources remain adequate for current and future requirements through monitoring, trending, and proactive scaling. Planning activities include performance monitoring, growth projection, and resource optimization.

Performance monitoring includes comprehensive metrics collection for CPU, memory, storage, and network utilization. Monitoring data provides the foundation for capacity planning decisions and optimization activities.

Growth projection includes analyzing historical trends, business growth plans, and seasonal variations to predict future capacity requirements. Projection activities guide infrastructure planning and budget allocation.

Resource optimization includes right-sizing activities, performance tuning, and efficiency improvements to maximize capacity utilization and minimize costs. Optimization activities ensure that resources are used effectively while maintaining performance requirements.

## Disaster Recovery

Disaster recovery design ensures business continuity through comprehensive backup strategies, geographic replication, and recovery procedures. The architecture supports various disaster scenarios including regional outages, data corruption, and security incidents.

### Backup Strategy

Backup strategy implementation provides comprehensive data protection through multiple backup types, retention policies, and storage locations. The strategy addresses both operational recovery and disaster recovery requirements.

Local backup configuration includes full database backups, differential backups, and transaction log backups with schedules appropriate for recovery point objectives. Local backups provide rapid recovery for operational scenarios.

Azure Blob Storage integration provides long-term backup retention and geographic replication for disaster recovery scenarios. Backup files are automatically transferred to Azure Storage with appropriate retention policies and access controls.

Backup testing includes regular restore testing to validate backup integrity and recovery procedures. Testing activities ensure that backup procedures meet business requirements and recovery time objectives.

### Geographic Replication

Geographic replication extends the high availability architecture to multiple Azure regions for disaster recovery and global read-scale scenarios. Replication configuration includes asynchronous replicas in secondary regions with appropriate network connectivity.

Cross-region networking includes VPN or ExpressRoute connections between regions to support replication traffic and administrative access. Network configuration ensures secure, reliable connectivity for replication operations.

Failover procedures include both planned and unplanned failover scenarios with appropriate coordination between regions. Procedures address data consistency, application redirection, and service restoration in secondary regions.

### Recovery Procedures

Recovery procedures provide systematic approaches to restoring services after various disaster scenarios. Procedures include both automated and manual recovery steps with appropriate documentation and testing.

Recovery time objectives (RTO) and recovery point objectives (RPO) guide recovery procedure design and implementation. Procedures are designed to meet business requirements for service restoration and data recovery.

Testing and validation include regular disaster recovery testing to validate procedures and identify improvement opportunities. Testing activities ensure that recovery procedures remain effective and current.

## Cost Analysis

Cost analysis provides comprehensive evaluation of deployment costs, optimization opportunities, and total cost of ownership considerations. The analysis includes both initial deployment costs and ongoing operational expenses.

### Infrastructure Costs

Infrastructure costs include virtual machine compute costs, storage costs, and networking costs for the complete high availability deployment. Cost analysis considers both on-demand pricing and reserved instance pricing for long-term deployments.

Virtual machine costs represent the largest component of infrastructure expenses with costs varying based on instance sizes, availability configurations, and regional pricing. Reserved instances provide significant cost savings for predictable workloads.

Storage costs include Premium SSD storage for database files and backup storage costs for Azure Blob Storage. Storage costs scale with database size and backup retention requirements.

Networking costs include load balancer costs, data transfer costs, and VPN or ExpressRoute costs for hybrid connectivity. Networking costs are typically minimal compared to compute and storage costs.

### Operational Costs

Operational costs include licensing, management, monitoring, and support costs associated with the SQL Server HA deployment. These costs may vary based on organizational requirements and service level agreements.

SQL Server licensing costs depend on the chosen licensing model including pay-as-you-go, bring-your-own-license, or Azure Hybrid Benefit options. Licensing optimization can provide significant cost savings for organizations with existing SQL Server licenses.

Management costs include administrative time, monitoring tools, and automation platform costs. Automation and monitoring integration can reduce management costs while improving operational efficiency.

### Cost Optimization

Cost optimization strategies help minimize total cost of ownership while maintaining required performance and availability characteristics. Optimization approaches include resource right-sizing, automation implementation, and operational efficiency improvements.

Resource optimization includes regular review of virtual machine sizing, storage utilization, and performance requirements to ensure appropriate resource allocation. Right-sizing activities can provide significant cost savings without impacting performance.

Automation implementation reduces operational costs through automated backup procedures, monitoring and alerting, and routine maintenance tasks. Automation provides both cost savings and operational benefits.

Reserved instance utilization provides significant cost savings for predictable workloads with one-year or three-year commitment options. Reserved instances can reduce compute costs by up to 72% compared to pay-as-you-go pricing.

## References

[1] Microsoft Azure Architecture Center - SQL Server on Azure Virtual Machines. Available at: https://docs.microsoft.com/en-us/azure/architecture/

[2] Microsoft Azure Documentation - Azure Virtual Machines. Available at: https://docs.microsoft.com/en-us/azure/virtual-machines/

[3] Microsoft SQL Server Documentation - Always On Availability Groups Architecture. Available at: https://docs.microsoft.com/en-us/sql/database-engine/availability-groups/windows/

[4] Microsoft Azure Documentation - Azure Load Balancer Architecture. Available at: https://docs.microsoft.com/en-us/azure/load-balancer/

[5] Microsoft Azure Documentation - Azure Virtual Network Architecture. Available at: https://docs.microsoft.com/en-us/azure/virtual-network/

[6] Microsoft Azure Documentation - Azure Storage Architecture. Available at: https://docs.microsoft.com/en-us/azure/storage/

[7] Microsoft Azure Documentation - Azure Security Architecture. Available at: https://docs.microsoft.com/en-us/azure/security/

[8] Microsoft SQL Server Documentation - High Availability Solutions. Available at: https://docs.microsoft.com/en-us/sql/sql-server/failover-clusters/

[9] Microsoft Azure Documentation - Azure Monitor Architecture. Available at: https://docs.microsoft.com/en-us/azure/azure-monitor/

[10] Microsoft Azure Documentation - Azure Cost Management. Available at: https://docs.microsoft.com/en-us/azure/cost-management-billing/

