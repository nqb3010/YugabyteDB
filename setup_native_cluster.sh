#!/bin/bash

# YugabyteDB 3-Node Native Cluster Setup
# Simple installation on HOST (like Docker but native)
# FIXED VERSION - Ensures all directories and permissions are correct

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Configuration
YB_VERSION="2025.2.2.1"
YB_HOME="/opt/yugabyte"
YB_USER="yugabyte"
YB_DATA_DIR="/opt/data"
YB_LOG_DIR="/var/log"
YB_FULL_DATA_DIR="${YB_DATA_DIR}/yugabyte"
YB_FULL_LOG_DIR="${YB_LOG_DIR}/yugabyte"

# Cluster IPs
NODE1_IP="192.168.37.4"
NODE2_IP="192.168.37.5"
NODE3_IP="192.168.37.6"

# Get current node IP
get_current_node() {
    local current_ip=$(hostname -I | awk '{print $1}')
    case $current_ip in
        $NODE1_IP) echo "node1" ;;
        $NODE2_IP) echo "node2" ;;
        $NODE3_IP) echo "node3" ;;
        *) echo "unknown" ;;
    esac
}

# Install dependencies
install_dependencies() {
    print_status "Installing dependencies..."
    
    # Update package list
    sudo apt update
    
    # Install required packages
    sudo apt install -y wget curl jq python3 python3-pip
    
    # Install ysqlsh if not available
    if ! command -v ysqlsh &> /dev/null; then
        print_status "ysqlsh not found, will use container version for testing"
    fi
    
    print_success "Dependencies installed"
}

# Create yugabyte user
create_user() {
    print_status "Creating yugabyte user..."
    
    if ! id "$YB_USER" &>/dev/null; then
        sudo useradd -r -m -d /home/yugabyte yugabyte
        print_success "Yugabyte user created"
    else
        print_status "Yugabyte user already exists"
    fi
}

# Create all necessary directories with proper permissions
create_all_directories() {
    print_status "Creating all necessary directories..."
    
    # Create base directories with proper permissions
    print_status "Creating base directories..."
    sudo mkdir -p $YB_HOME
    sudo mkdir -p $YB_FULL_DATA_DIR
    sudo mkdir -p $YB_FULL_LOG_DIR
    
    # Create data directories
    print_status "Creating data directories..."
    sudo mkdir -p $YB_FULL_DATA_DIR/master
    sudo mkdir -p $YB_FULL_DATA_DIR/tserver
    sudo mkdir -p $YB_FULL_DATA_DIR/master/wal
    sudo mkdir -p $YB_FULL_DATA_DIR/tserver/wal
    sudo mkdir -p $YB_FULL_DATA_DIR/master/yb-data/master/consensus-meta
    
    # Create log directories
    print_status "Creating log directories..."
    sudo mkdir -p $YB_FULL_LOG_DIR/master
    sudo mkdir -p $YB_FULL_LOG_DIR/tserver
    
    # Set ownership for all directories
    print_status "Setting ownership..."
    sudo chown -R $YB_USER:$YB_USER $YB_HOME
    sudo chown -R $YB_USER:$YB_USER $YB_FULL_DATA_DIR
    sudo chown -R $YB_USER:$YB_USER $YB_FULL_LOG_DIR
    
    # Set proper permissions
    print_status "Setting permissions..."
    sudo chmod -R 755 $YB_HOME
    sudo chmod -R 755 $YB_FULL_DATA_DIR
    sudo chmod -R 755 $YB_FULL_LOG_DIR
    
    # Verify directories exist
    print_status "Verifying directories..."
    local dirs=(
        "$YB_HOME"
        "$YB_FULL_DATA_DIR/master"
        "$YB_FULL_DATA_DIR/tserver"
        "$YB_FULL_DATA_DIR/master/wal"
        "$YB_FULL_DATA_DIR/tserver/wal"
        "$YB_FULL_LOG_DIR/master"
        "$YB_FULL_LOG_DIR/tserver"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            print_error "Directory $dir does not exist!"
            exit 1
        fi
        if [[ ! "$(stat -c %U $dir)" == "$YB_USER" ]]; then
            print_error "Directory $dir not owned by $YB_USER!"
            exit 1
        fi
    done
    
    print_success "All directories created and verified"
}

# Download and install YugabyteDB
install_yugabytedb() {
    print_status "Downloading and installing YugabyteDB ${YB_VERSION}..."
    
    # Download YugabyteDB
    cd /tmp
    if [ ! -f "yugabyte-${YB_VERSION}-b1-linux-x86_64.tar.gz" ]; then
        wget "https://software.yugabyte.com/releases/${YB_VERSION}/yugabyte-${YB_VERSION}-b1-linux-x86_64.tar.gz"
    fi
    
    # Extract and install
    tar -xzf yugabyte-${YB_VERSION}-b1-linux-x86_64.tar.gz
    sudo rm -rf $YB_HOME/*
    sudo cp -r yugabyte-${YB_VERSION}/* $YB_HOME/
    
    # Set permissions
    sudo chown -R $YB_USER:$YB_USER $YB_HOME
    sudo chmod +x $YB_HOME/bin/*
    
    # Add to PATH
    echo "export PATH=\$PATH:$YB_HOME/bin" | sudo tee -a /etc/profile.d/yugabyte.sh
    
    print_success "YugabyteDB installed"
}

# Create systemd services
create_systemd_services() {
    local current_node=$(get_current_node)
    local node_num=${current_node: -1}
    local current_ip
    
    case $current_node in
        "node1") current_ip=$NODE1_IP ;;
        "node2") current_ip=$NODE2_IP ;;
        "node3") current_ip=$NODE3_IP ;;
        *) print_error "Unknown node"; exit 1 ;;
    esac
    
    print_status "Creating systemd services for $current_node ($current_ip)..."
    
    # Create yb-master service
    sudo tee /etc/systemd/system/yb-master.service > /dev/null <<EOF
[Unit]
Description=YugabyteDB Master
After=network.target

[Service]
Type=simple
User=$YB_USER
Group=$YB_USER
ExecStart=$YB_HOME/bin/yb-master \\
    --master_addresses=$NODE1_IP:7100,$NODE2_IP:7100,$NODE3_IP:7100 \\
    --rpc_bind_addresses=0.0.0.0:7100 \\
    --server_broadcast_addresses=$current_ip:7100 \\
    --webserver_port=7000 \\
    --fs_data_dirs=$YB_FULL_DATA_DIR/master \\
    --fs_wal_dirs=$YB_FULL_DATA_DIR/master/wal \\
    --log_dir=$YB_FULL_LOG_DIR/master \\
    --replication_factor=3 \\
    --enable_ysql=true
Restart=always
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    # Create yb-tserver service
    sudo tee /etc/systemd/system/yb-tserver.service > /dev/null <<EOF
[Unit]
Description=YugabyteDB Tablet Server
After=yb-master.service

[Service]
Type=simple
User=$YB_USER
Group=$YB_USER
ExecStart=$YB_HOME/bin/yb-tserver \\
    --tserver_master_addrs=$NODE1_IP:7100,$NODE2_IP:7100,$NODE3_IP:7100 \\
    --rpc_bind_addresses=0.0.0.0:9101 \\
    --server_broadcast_addresses=$current_ip:9101 \\
    --webserver_port=9000 \\
    --pgsql_proxy_bind_address=0.0.0.0:5433 \\
    --fs_data_dirs=$YB_FULL_DATA_DIR/tserver \\
    --fs_wal_dirs=$YB_FULL_DATA_DIR/tserver/wal \\
    --log_dir=$YB_FULL_LOG_DIR/tserver \\
    --enable_ysql=true
Restart=always
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd
    sudo systemctl daemon-reload
    
    print_success "Systemd services created"
}

# Stop existing services and clean data
stop_and_clean() {
    print_status "Stopping existing YugabyteDB services..."
    
    sudo systemctl stop yb-master yb-tserver 2>/dev/null || true
    sudo systemctl disable yb-master yb-tserver 2>/dev/null || true
    
    # Kill any existing processes
    sudo pkill -f yb-master 2>/dev/null || true
    sudo pkill -f yb-tserver 2>/dev/null || true
    
    # Wait for processes to stop
    sleep 5
    
    # COMPLETE CLEANUP - Remove all data to prevent FSManager root not empty error
    print_status "Performing complete cleanup..."
    
    # Remove entire yugabyte data directory
    if [[ -d "$YB_FULL_DATA_DIR" ]]; then
        print_status "Removing data directory: $YB_FULL_DATA_DIR"
        sudo rm -rf $YB_FULL_DATA_DIR
    fi
    
    # Remove entire yugabyte log directory
    if [[ -d "$YB_FULL_LOG_DIR" ]]; then
        print_status "Removing log directory: $YB_FULL_LOG_DIR"
        sudo rm -rf $YB_FULL_LOG_DIR
    fi
    
    # Remove installation directory
    if [[ -d "$YB_HOME" ]]; then
        print_status "Cleaning installation directory: $YB_HOME"
        sudo rm -rf $YB_HOME/*
    fi
    
    # Remove systemd service files
    print_status "Removing old service files..."
    sudo rm -f /etc/systemd/system/yb-master.service
    sudo rm -f /etc/systemd/system/yb-tserver.service
    
    # Reload systemd to remove old services
    sudo systemctl daemon-reload
    
    # Recreate all directories from scratch
    create_all_directories
    
    print_success "Complete cleanup finished - ready for fresh installation"
}

# Start services with retry logic
start_services() {
    print_status "Starting YugabyteDB services..."
    
    # Start master with retry
    print_status "Starting yb-master..."
    local master_retry=0
    while [ $master_retry -lt 3 ]; do
        sudo systemctl start yb-master
        sudo systemctl enable yb-master
        
        print_status "Waiting for master to start... (attempt $((master_retry + 1))/3)"
        sleep 30
        
        if sudo systemctl is-active --quiet yb-master; then
            print_success "yb-master started successfully"
            break
        else
            print_warning "yb-master failed to start, cleaning and retrying..."
            sudo systemctl stop yb-master
            sudo rm -rf $YB_FULL_DATA_DIR/master/*
            sudo mkdir -p $YB_FULL_DATA_DIR/master/wal
            sudo chown -R yugabyte:yugabyte $YB_FULL_DATA_DIR/master
            master_retry=$((master_retry + 1))
        fi
    done
    
    if ! sudo systemctl is-active --quiet yb-master; then
        print_error "yb-master failed to start after 3 attempts"
        sudo systemctl status yb-master --no-pager
        print_error "Check logs: sudo tail -f $YB_FULL_LOG_DIR/master/yb-master.FATAL.details.*"
        exit 1
    fi
    
    # Start tablet server with retry
    print_status "Starting yb-tserver..."
    local tserver_retry=0
    while [ $tserver_retry -lt 3 ]; do
        sudo systemctl start yb-tserver
        sudo systemctl enable yb-tserver
        
        print_status "Waiting for tablet server to start... (attempt $((tserver_retry + 1))/3)"
        sleep 30
        
        if sudo systemctl is-active --quiet yb-tserver; then
            print_success "yb-tserver started successfully"
            break
        else
            print_warning "yb-tserver failed to start, cleaning and retrying..."
            sudo systemctl stop yb-tserver
            sudo rm -rf $YB_FULL_DATA_DIR/tserver/*
            sudo mkdir -p $YB_FULL_DATA_DIR/tserver/wal
            sudo chown -R yugabyte:yugabyte $YB_FULL_DATA_DIR/tserver
            tserver_retry=$((tserver_retry + 1))
        fi
    done
    
    if ! sudo systemctl is-active --quiet yb-tserver; then
        print_error "yb-tserver failed to start after 3 attempts"
        sudo systemctl status yb-tserver --no-pager
        print_error "Check logs: sudo tail -f $YB_FULL_LOG_DIR/tserver/yb-tserver.FATAL.details.*"
        exit 1
    fi
    
    print_success "All services started successfully"
}

# Check cluster health
check_cluster_health() {
    local current_ip
    
    case $(get_current_node) in
        "node1") current_ip=$NODE1_IP ;;
        "node2") current_ip=$NODE2_IP ;;
        "node3") current_ip=$NODE3_IP ;;
        *) current_ip="localhost" ;;
    esac
    
    print_status "Checking cluster health..."
    
    # Check service status
    echo "Service status:"
    sudo systemctl status yb-master yb-tserver --no-pager | grep -E "Active:" || echo "Services not running"
    
    # Check master API
    echo ""
    echo "Master API:"
    if curl -s --max-time 5 "http://$current_ip:7000/api/v1/masters" > /dev/null; then
        local master_count=$(curl -s "http://$current_ip:7000/api/v1/masters" | jq '. | length' 2>/dev/null || echo "0")
        echo "Masters found: $master_count"
        
        echo "Master roles:"
        curl -s "http://$current_ip:7000/api/v1/masters" | grep -o '"role":"[^"]*"' 2>/dev/null || echo "No roles found"
    else
        print_error "Master API not responding"
    fi
    
    # Check tablet servers
    echo ""
    echo "Tablet servers:"
    local tablet_count=$(curl -s "http://$current_ip:7000/api/v1/tablet-servers" | grep -o '"live_tablet_servers":[0-9]*' | grep -o '[0-9]*' 2>/dev/null || echo "0")
    echo "Live tablet servers: $tablet_count"
}

# Test database connection
test_database() {
    print_status "Testing database connection..."
    
    # Test with ysqlsh if available
    if command -v ysqlsh &> /dev/null; then
        if timeout 10 ysqlsh -h localhost -p 5433 -c "SELECT 1;" >/dev/null 2>&1; then
            print_success "Database connection successful"
        else
            print_error "Database connection failed"
        fi
    else
        print_warning "ysqlsh not available, install with: sudo apt install postgresql-client"
    fi
}

# Show access information
show_access_info() {
    local current_ip
    
    case $(get_current_node) in
        "node1") current_ip=$NODE1_IP ;;
        "node2") current_ip=$NODE2_IP ;;
        "node3") current_ip=$NODE3_IP ;;
        *) current_ip="localhost" ;;
    esac
    
    print_success "YugabyteDB Native Cluster is ready!"
    echo ""
    echo "🌍 EXTERNAL ACCESS POINTS:"
    echo "=========================="
    echo ""
    echo "📊 Master Web UI:"
    echo "   Local: http://localhost:7000"
    echo "   External: http://$current_ip:7000"
    echo ""
    echo "🗄️  Database Connection:"
    echo "   Local: ysqlsh -h localhost -p 5433"
    echo "   External: ysqlsh -h $current_ip -p 5433 -U yugabyte"
    echo ""
    echo "📈 Tablet Server UI:"
    echo "   Local: http://localhost:9000"
    echo "   External: http://$current_ip:9000"
    echo ""
    echo "🔧 Management Commands:"
    echo "   Stop services: sudo systemctl stop yb-master yb-tserver"
    echo "   Start services: sudo systemctl start yb-master yb-tserver"
    echo "   View logs: sudo tail -f $YB_FULL_LOG_DIR/master/yb-master.INFO"
    echo "   Check status: sudo systemctl status yb-master yb-tserver"
    echo ""
    echo "🌐 All Cluster Nodes:"
    echo "   Node 1: $NODE1_IP:7000 (Master), $NODE1_IP:5433 (Database)"
    echo "   Node 2: $NODE2_IP:7000 (Master), $NODE2_IP:5433 (Database)"
    echo "   Node 3: $NODE3_IP:7000 (Master), $NODE3_IP:5433 (Database)"
}

# Main function
main() {
    echo "=========================================="
    echo "  YugabyteDB 3-Node Native Cluster Setup"
    echo "      Simple Installation on HOST"
    echo "      FIXED VERSION - All directories ensured"
    echo "=========================================="
    echo ""
    
    local current_node=$(get_current_node)
    print_status "Current node: $current_node"
    
    if [ "$current_node" = "unknown" ]; then
        print_error "Unknown node IP. Expected: $NODE1_IP, $NODE2_IP, $NODE3_IP"
        exit 1
    fi
    
    install_dependencies
    create_user
    stop_and_clean
    install_yugabytedb
    create_systemd_services
    start_services
    check_cluster_health
    test_database
    show_access_info
}

# Run main function
main "$@"
