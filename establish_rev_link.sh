#!/bin/bash

#
# [Clients] --> [VPS] --> [GATEWAY] --> [Internet]
#
# The scripts creates a SSH reverse tunnel on the VPS (target server). Clients
# access the GATEWAY through VPS (configure sshd.GatewayPorts=yes). A
# proxy-server (e.g., Shadowsocks) terminate connections on GATEWAY and route
# to internet.
#

CURDIR=$(dirname "$0")
NS="blue"

source "$CURDIR/config.sh"

TMP_PREV_IP_FRWD_STATE=$(sudo sysctl net.ipv4.ip_forward | cut -d ' ' -f 3)

setup_env() {
	# Create namespace and configure veth and its routing
	sudo ip netns add $NS
	sudo ip link add veth-root type veth peer name veth-blue
	sudo ip link add veth-remote type veth peer name veth-red

	sudo ip link set veth-blue netns $NS
	sudo ip link set veth-red netns $NS

	sudo ip link set veth-root up
	sudo ip addr add 192.168.100.1/24 dev veth-root
	sudo ip netns exec $NS ip link set veth-blue up
	sudo ip netns exec $NS ip addr add 192.168.100.2/24 dev veth-blue

	sudo ip link set veth-remote up
	sudo ip addr add 192.168.200.1/24 dev veth-remote
	sudo ip netns exec $NS ip link set veth-red up
	sudo ip netns exec $NS ip addr add 192.168.200.2/24 dev veth-red

	sudo ip netns exec $NS ip link set lo up

	sudo ip netns exec $NS ip route add "$TARGET_SERVER/32" via 192.168.200.1 dev veth-red
	sudo iptables -t nat -A POSTROUTING -s 192.168.200.0/24 -o $IFNAME_DARKSIDE -j MASQUERADE

	# TODO: filter local/unwanted IP addresses
	sudo iptables exec $NS ip route add default via 192.168.100.1 dev veth-blue
	sudo iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o $IFNAME_LIGHTSIDE -j MASQUERADE

	sudo sysctl -w net.ipv4.ip_forward=1

	# TODO: configure what IPs can be routed
	# sudo ip netns exec $NS ip route add "104.18.26.0/24" via 192.168.100.1 dev veth-blue
}

teardown_env() {
	sudo sysctl -w net.ipv4.ip_forward="$TMP_PREV_IP_FRWD_STATE"
	sudo iptables -t nat -D POSTROUTING -s 192.168.200.0/24 -o $IFNAME_DARKSIDE -j MASQUERADE
	sudo iptables -t nat -D POSTROUTING -s 192.168.100.0/24 -o $IFNAME_LIGHTSIDE -j MASQUERADE
	sudo ip link delete veth-remote
	sudo ip link delete veth-root
	sudo ip netns delete $NS
}

open_rev_tunnel() {
	TMP_USE_SSH_KEY=""
	if [ -n "$TARGET_SERVER_SSH_PRIVATE_KEY" ]; then
		TMP_USE_SSH_KEY="-i $TARGET_SERVER_SSH_PRIVATE_KEY"
	fi
	sudo ip netns exec $NS \
		ssh -N \
			"$TMP_USE_SSH_KEY" \
			-R "$TARGET_SERVER":"$TARGET_SERVER_FORWARD_PORT":127.0.0.1:"$LOCAL_LISTEN_PORT" \
			-p $TARGET_SERVER_SSH_PORT \
			$TARGET_SERVER_USER@$TARGET_SERVER
}

launch_proxy_server() {
	sudo ip netns exec $NS bash "$CURDIR/run_ss.sh"
}

RUNNING=1
on_signal() {
	RUNNING=0
}

wait_until_ctrl_c() {
	trap "on_signal" SIGINT SIGHUP
	while [ $RUNNING -ne 0 ]; do
		sleep 5
	done
}

main() {
	setup_env
	# launch_proxy_server
	open_rev_tunnel
	# wait_until_ctrl_c
	teardown_env
}

# -----
main

