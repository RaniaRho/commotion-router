#===============================================================================
#
#          FILE:  mesh.sh
# 
#         USAGE:  include /lib/network
# 
#   DESCRIPTION:  This file attempts to be a clean and simple implementation of 
#                 an autoconfiguring mesh network using OpenWRT's native 
#                 network configuration methods and utilities. It implements 3
#                 new interface "protocols": meshif (mesh backhaul interface), 
#                 apif (wireless access point interface), and plugif (part of a 
#                 hot-swappable ethernet implementation switching between DHCP 
#                 gateway and DHCP server for client access). Initially uses 
#                 OLSRd and IPv4, additional options for batman-adv and IPv6 
#                 forthcoming.
# 
#       AUTHOR:  Josh King
#       CREATED:  11/19/2010 02:44:44 PM EST
#       REVISION:  ---
#       LICENSE:  GPLv3
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of version 3 of the GNU General Public
# License as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA
#===============================================================================

#DEBUG="echo"

#===============================================================================
# DEFAULTS
#===============================================================================

DEFAULT_MESH_SSID="commotion-mesh"
DEFAULT_MESH_BSSID="02:CA:FF:EE:BA:BE"
DEFAULT_MESH_CHANNEL="5"
DEFAULT_MESH_BASENAME="commotion"
DEFAULT_MESH_PREFIX="5"
DEFAULT_MESH_FWZONE="mesh"
DEFAULT_AP_PREFIX="101"
DEFAULT_AP_FWZONE="ap"
DEFAULT_LAN_PREFIX="102"

#===============================================================================
# SETTING FUNCTIONS
#===============================================================================

#===  FUNCTION  ================================================================
#          NAME:  set_meshif_wireless
#   DESCRIPTION:  Sets wireless of the mesh interface based on network config
#    PARAMETERS:  Config name for network.
#       RETURNS:  0 == success, 1 == failure
#===============================================================================

set_meshif_wireless() {
  local config="$1"
  local ssid=$(uci_get mesh network ssid "$DEFAULT_MESH_SSID") 
  local ssid=$(uci_get mesh network bssid "$DEFAULT_MESH_BSSID") 
  local channel=$(uci_get mesh network channel "$DEFAULT_MESH_CHANNEL") 
  local net dev

  config_cb() {
    local type="$1"
    local name="$2"
    local network device
    case "$type" in
      wifi-iface)
        network=$(uci_get wireless "$name" network)
        device=$(uci_get wireless "$name" device)
        case "$network" in
          "$config")
            net="$name"
            dev="$device"
            ;;
        esac
        ;;
    esac
  }
  config_load wireless

  [[ -n "$net" ]] && [[ -n "$dev" ]] && \
  uci_set wireless "$net" ssid "$ssid" && uci_set wireless "$dev" channel "$channel" && uci_commit wireless && return 0

  logger -t set_apif_wireless "Error! Wireless configuration for "$config" may not exist." && return 1
}


#===  FUNCTION  ================================================================
#          NAME:  set_apif_wireless
#   DESCRIPTION:  Wireless settings for the AP interface based on network config
#    PARAMETERS:  Config name for the AP network.
#       RETURNS:  0 == success, 1 == failure
#===============================================================================
set_apif_wireless() {
  local iface="$1"
  local config="$2"
  local wiconfig=
  local basename=$(uci_get mesh network basename "$DEFAULT_MESH_BASENAME")
  local location=$(uci_get mesh node location)
  ifconfig "$iface" 2>/dev/null >/dev/null && {
    local mac=`ifconfig "$iface" | grep 'Link encap:'| awk '{ print $5}'`;
  } || logger -t set_apif_wireless "Error! Interface "$iface" doesn't exist!"; return 1

  config_cb() {
    local type="$1"
    local name="$2"
    case "$type" in
      wifi-iface)
        network=$(uci_get wireless "$name" network)
        case "$network" in
          "$config")
            wiconfig="$name"
            ;;
        esac
        ;;
    esac
  }
  config_load wireless
  [[ -n "$wiconfig" ]] && [[ -n "$location" ]] && 
  uci_set wireless "$wiconfig" ssid "$basename"-ap_"$location" && uci_commit wireless && return 0

  [[ -n "$wiconfig" ]] && [[ -z "$location" ]] && \
  uci_set wireless "$wiconfig" ssid "$basename"-ap_$( cat /sys/class/net/$iface/address | \
   awk -F ':' '{ printf("%d_%d_%d","0x"$4,"0x"$5,"0x"$6) }' ) && uci_commit wireless && return 0

  logger -t set_apif_wireless "Error! Wireless configuration for "$config" may not exist." && return 1
}


#===  FUNCTION  ================================================================
#          NAME:  unset_fwzone
#   DESCRIPTION:  Removes an interface from the firewall zone.
#    PARAMETERS:  1; config name of network
#       RETURNS:  0 on success
#===============================================================================

unset_fwzone() {
  local config="$1"
  
  config_load firewall
  config_cb() {
    local type="$1"
    local name="$2"
    case $type in
      zone)
        local oldnetworks=
        config_get oldnetworks "$name" network  
        local newnetworks=
        for net in $(sort_list "$oldnetworks" "$config"); do
          list_remove newnetworks "$net"
        done
        uci_set firewall "$name" network "$newnetworks"
        ;;
    esac
  }
  config_load firewall

  uci_commit firewall && return 0
}
  
#===  FUNCTION  ================================================================
#          NAME:  set_fwzone
#   DESCRIPTION:  Adds an interface to the mesh firewall zone.
#    PARAMETERS:  2; config name of network and firewall zone to set it to.
#       RETURNS:  0 on success
#===============================================================================

set_fwzone() {
  local config="$1"
  local zone="$2"

  reset_cb 
  config_load firewall
  config_cb() {
    local type="$1"
    local name="$2"
    local fwname=
    case $type in
      zone)
        local fwname=$(uci_get firewall "$name" name)
        case "$fwname" in
          "$zone")
            local oldnetworks=
            config_get oldnetworks "$name" network  
            local newnetworks=
            for net in $(sort_list "$oldnetworks" "$config"); do
              append newnetworks "$net"
            done
            uci_set firewall "$name" network "$newnetworks"
            ;;
        esac
        ;;
    esac
  }
  config_load firewall

  uci_commit firewall && return 0
}

#===  FUNCTION  ================================================================
#          NAME:  unset_olsrd_if
#   DESCRIPTION:  Unsets the interface stanza for the olsrd config
#    PARAMETERS:  config name of the interface to remove
#       RETURNS:  0 on success
#===============================================================================

unset_olsrd_if() {
  local config="$1"
  
  config_load olsrd
  config_cb() {
    local type="$1"
    local name="$2"

    case $type in
      Interface)
        config_get oldifaces "$name" interface  
        local newifaces=
        for dev in $(sort_list "$oldifaces" "$config"); do
          list_remove newifaces "$dev"
        done
        uci_set olsrd "$name" interface "$newifaces"
        ;;
    esac
  }
  config_load olsrd

  uci_commit olsrd && return 0
}

#===  FUNCTION  ================================================================
#          NAME:  set_olsrd_if
#   DESCRIPTION:  Sets the interface stanza for the olsrd config
#    PARAMETERS:  config name of the interface to add
#       RETURNS:  0 on success
#===============================================================================

set_olsrd_if() {
  local config="$1"
  config_cb() {
    local type="$1"
    local name="$2"

    case $type in
      Interface)
        config_get oldifaces "$name" interface  
        local newifaces=
        for dev in $(sort_list "$oldifaces" "$config"); do
          append newifaces "$dev"
        done
        uci_set olsrd "$name" interface "$newifaces"
        ;;
    esac
  }
  config_load olsrd

  uci_commit olsrd && return 0
}

#===  FUNCTION  ================================================================
#          NAME:  unset_olsrd_p2pif
#   DESCRIPTION:  Unsets the p2p plugin stanza for the olsrd config
#    PARAMETERS:  config name of the interface to remove
#       RETURNS:  0 on success
#===============================================================================

unset_olsrd_p2pif() {
  local iface="$1"
  
  config_load olsrd
  config_cb() {
    local type="$1"
    local name="$2"
    local library=

    case $type in
      LoadPlugin)
        config_get NonOlsrIf "$name" NonOlsrIf  
        case $NonOlsrIf in
          "$iface")
            uci_remove olsrd "$name" NonOlsrIf
            ;;
        esac
      ;;
    esac
  }
  config_load olsrd

  uci_commit olsrd && return 0
}

#===  FUNCTION  ================================================================
#          NAME:  set_olsrd_p2pif
#   DESCRIPTION:  Sets the interface stanza for the olsrd config
#    PARAMETERS:  
#       RETURNS:  
#===============================================================================

set_olsrd_p2pif() {
  local iface="$1"
  
  config_load olsrd
  config_cb() {
    local type="$1"
    local name="$2"
    local library=

    case $type in
      LoadPlugin)
        config_get library "$name" library  
        case $library in
          "olsrd_p2pd.so.0.1.0")
            uci_set olsrd "$name" NonOlsrIf "$iface"
            ;;
        esac
      ;;
    esac
  }
  config_load olsrd

  uci_commit olsrd && return 0
}

#===  FUNCTION  ================================================================
#          NAME:  unset_olsrd_hna4
#   DESCRIPTION:  Unset HNA4 stanza in olsrd config
#    PARAMETERS:  1; IPv4 address of network to unset
#       RETURNS:  0 on success, 1 on failure
#===============================================================================

unset_olsrd_hna4() {
  local config=$1
  
  uci_remove olsrd "$config"
        
  uci_commit olsrd && return 0
}

#===  FUNCTION  ================================================================
#          NAME:  set_olsrd_hna4
#   DESCRIPTION:  Set HNA4 stanza in olsrd config
#    PARAMETERS:  2; IPv4 address and netmask to set
#       RETURNS:  0 on success, 1 on failure
#===============================================================================

set_olsrd_hna4() {
  local ipv4addr=$1
  local netmask=$2
  local config=$3

  #Remove duplicates  
  #unset_olsrd_hna4 ipv4addr

  uci_add olsrd Hna4 "$config" 
  uci_set olsrd @Hna4[-1] netaddr "$ipv4addr"
  uci_set olsrd @Hna4[-1] netmask "$netmask"

  uci_commit olsrd && return 0
} 

#===  FUNCTION  ================================================================
#          NAME:  unset_dnsmasq_if
#   DESCRIPTION:  Unset dnsmasq DHCP settings
#    PARAMETERS:  
#       RETURNS:  
#===============================================================================

unset_dnsmasq_if() {
  local config="$1"
 
  #For some reason requires pre-load to parse options. 
  config_load dhcp
  config_cb() {
    local type="$1"
    local name="$2"
    local interface=
  
    case "$type" in
      dhcp) 
        config_get interface "$name" interface 
        case "$interface" in
          "$config")
            uci_remove dhcp "$name"
            ;; 
        esac
        ;;
    esac
  }
  config_load dhcp
  
  uci_add dhcp dhcp 
  uci_set dhcp @dhcp[-1] interface "$config"
  uci_set dhcp @dhcp[-1] ignore "1"
  uci_commit dhcp && return 0
}

#===  FUNCTION  ================================================================
#          NAME:  set_dnsmasq_if
#   DESCRIPTION:  Set dnsmasq DHCP settings
#    PARAMETERS:  
#       RETURNS:  
#===============================================================================

set_dnsmasq_if() {
  local config="$1"
  #local ipv4addr="$2"
  
  #Possible race condition causes this check to create an erroneous interface.
  #unset_dnsmasq_if
  
  config_cb() {
    local type="$1"
    local name="$2"
    local interface=
  
    case "$type" in
      dhcp) 
        config_get interface "$name" interface 
        case "$interface" in
          "$config")
            uci_set dhcp "$name" interface "$config"
            uci_set dhcp "$name" start "2"
            uci_set dhcp "$name" limit "252"
            uci_set dhcp "$name" leasetime "12h"
            uci_set dhcp "$name" ignore "0"
            ;; 
        esac
    esac
  }
  config_load dhcp
      
  uci_commit dhcp && return 0
}

#===============================================================================
# PROTOCOL HANDLERS
#===============================================================================

#===  FUNCTION  ================================================================
#          NAME:  setup_interface_meshif
#   DESCRIPTION:  The function called by OpenWRT for proto 'meshif' interfaces.
#    PARAMETERS:  2; config name and interface
#       RETURNS:  
#===============================================================================

setup_interface_meshif() {
  local iface="$1"
  local config="$2"

  env -i ACTION="preup" INTERFACE="$config" DEVICE="$iface" PROTO=meshif /sbin/hotplug-call "services" &
  
  local ipaddr netmask reset
  config_get_bool reset "$config" reset 1
  case "$reset" in
    1)
      local prefix=$(uci_get mesh network mesh_prefix "$DEFAULT_MESH_PREFIX")
      $DEBUG set_olsrd_if "$config"
      $DEBUG unset_dnsmasq_if "$config"
      $DEBUG /etc/init.d/dnsmasq restart
      $DEBUG set_meshif_wireless "$config"
      $DEBUG set_fwzone "$config" $(uci_get mesh network mesh_zone "$DEFAULT_MESH_FWZONE")
      $DEBUG uci_set network "$config" ipaddr $( cat /sys/class/net/$iface/address | \
      awk -F ':' '{ printf("$prefix.%d.%d.%d","0x"$4,"0x"$5,"0x"$6) }' )
      $DEBUG uci_set network "$config" netmask "255.0.0.0"
      $DEBUG uci_set network "$config" broadcast "255.255.255.255"
      $DEBUG uci_set network "$config" reset 0
      uci_commit network
      scan_interfaces
      ;;
  esac

  config_get ipaddr "$config" ipaddr
  config_get netmask "$config" netmask
  config_get bcast "$config" broadcast
  config_get dns "$config" dns
  [ -z "$ipaddr" ] || $DEBUG ifconfig "$iface" "$ipaddr" netmask "$netmask" broadcast "${bcast:-+}"
  [ -z "$dns" ] || add_dns "$config" $dns

  config_get type "$config" TYPE
  [ "$type" = "alias" ] && return 0

  env -i ACTION="ifup" INTERFACE="$config" DEVICE="$iface" PROTO=meshif /sbin/hotplug-call "iface" &
}

coldplug_interface_meshif() {
  local config="$1"
  local reset=0

  [ -z $(config_get_bool reset "$config" 1) ] && return 0
  $DEBUG set_meshif_wireless "$config"
  $DEBUG config_get iface "$config" iface
  $DEBUG setup_interface_meshif "$iface" "$config"
}

#===  FUNCTION  ================================================================
#          NAME:  setup_interface_apif
#   DESCRIPTION:  The function called by OpenWRT for proto 'apif' interfaces.
#    PARAMETERS:  2; config name and interface
#       RETURNS:  
#===============================================================================

setup_interface_apif() {
  local iface="$1"
  local config="$2"
  
  env -i ACTION="preup" INTERFACE="$config" DEVICE="$iface" PROTO=apif /sbin/hotplug-call "services" &

  local ipaddr netmask reset
  config_get_bool reset "$config" reset 1
  case "$reset" in
    1)
      local prefix=$(uci_get mesh network ap_prefix "$DEFAULT_AP_PREFIX")
      $DEBUG set_apif_wireless "$iface" "$config"
      $DEBUG set_apif_fwzone "$config"
      $DEBUG set_fwzone "$config" $(uci_get mesh network ap_zone "$DEFAULT_AP_FWZONE")
      $DEBUG uci_set network "$config" ipaddr $( cat /sys/class/net/$iface/address | \
      awk -F ':' '{ printf("$prefix.%d.%d.1","0x"$5,"0x"$6) }' )
      $DEBUG uci_set network "$config" netmask "255.255.255.0"
      $DEBUG uci_set network "$config" broadcast $( cat /sys/class/net/$iface/address | \
      awk -F ':' '{ printf("$prefix.%d.%d.255","0x"$5,"0x"$6) }' )
      $DEBUG uci_set network "$config" reset 0
      uci_commit network
      scan_interfaces
      ;;
  esac

  config_get ipaddr "$config" ipaddr
  config_get netmask "$config" netmask
  config_get bcast "$config" broadcast
  config_get dns "$config" dns
  [ -z "$ipaddr" ] || $DEBUG ifconfig "$iface" "$ipaddr" netmask "$netmask" broadcast "${bcast:-+}"
  [ -z "$dns" ] || add_dns "$config" $dns

  config_get type "$config" TYPE
  [ "$type" = "alias" ] && return 0

  env -i ACTION="ifup" INTERFACE="$config" DEVICE="$iface" PROTO=apif /sbin/hotplug-call "iface" &
}

coldplug_interface_apif() {
  local config="$1"
  local reset=0

  [ -z $(config_get_bool reset "$config" 1) ] && return 0
  $DEBUG set_apif_wireless "$config"
  $DEBUG config_get iface "$config" iface
  $DEBUG setup_interface_apif "$iface" "$config"
}

#===  FUNCTION  ================================================================
#          NAME:  setup_interface_plugif
#   DESCRIPTION:  
#    PARAMETERS:  
#       RETURNS:  
#===============================================================================

setup_interface_plugif() {
  local iface="$1"
  local config="$2"
      
  env -i ACTION="preup" INTERFACE="$config" DEVICE="$iface" PROTO=plugif /sbin/hotplug-call "services" &

  # kill running udhcpc instance                                                                            
  local pidfile="/var/run/dhcp-${iface}.pid"                                                                
  [ -e "$pidfile" ] && \
  $DEBUG service_kill udhcpc "$pidfile"                                                                            

  #Attempt to acquire address.
  local ipaddr netmask hostname proto1 clientid vendorid broadcast                                          
  config_get ipaddr "$config" ipaddr                                                                        
  config_get netmask "$config" netmask                            
  config_get hostname "$config" hostname                          
  config_get proto1 "$config" proto                               
  config_get clientid "$config" clientid                          
  config_get vendorid "$config" vendorid                          
  config_get_bool broadcast "$config" broadcast 0                 
                                                                     
  [ -z "$ipaddr" ] || $DEBUG ifconfig "$iface" "$ipaddr" ${netmask:+netmask "$netmask"}
  set_plugif_fwzone_wan "$config"
  $DEBUG set_fwzone "$config" $(uci_get mesh network wan_zone "wan")
                                                                                                
  # don't stay running in background.
  local dhcpopts="-n -q"                                                         
  [ "$broadcast" = 1 ] && broadcast="-O broadcast" || broadcast=                                          
                                                                                                                               
	$DEBUG eval udhcpc -i "$iface" \
		${ipaddr:+-r $ipaddr} \
		${hostname:+-H $hostname} \
		${clientid:+-c $clientid} \
		${vendorid:+-V $vendorid} \
		-p "$pidfile" $broadcast \
		${dhcpopts:- -O rootpath -R &}

  case "$?" in
    1)
      local prefix=$(uci_get mesh network lan_prefix "$DEFAULT_LAN_PREFIX")
      $DEBUG uci_set_state network "$config" ipaddr $( cat /sys/class/net/$iface/address | \
      awk -F ':' '{ printf("$prefix.%d.%d.1","0x"$5,"0x"$6) }' )
      $DEBUG uci_set_state network "$config" netmask "255.255.255.0"
      $DEBUG uci_set_state network "$config" broadcast $( cat /sys/class/net/$iface/address | \
      awk -F ':' '{ printf("$prefix.%d.%d.255","0x"$5,"0x"$6) }' )
      local ipaddr="$(uci_get_state network "$config" ipaddr)"
      local netmask="$(uci_get_state network "$config" netmask)"
      local broadcast="$(uci_get_state network "$config" broadcast)"
      local dns="$(uci_get_state network "$config" dns)"
      [ -z "$ipaddr" ] || ifconfig "$iface" inet "$ipaddr" netmask "$netmask" broadcast "${broadcast:-+}"
      [ -z "$dns" ] || add_dns "$config" $dns
      
      $DEBUG set_fwzone "$config" $(uci_get mesh network lan_zone "lan")
      ;;
  esac
  env -i ACTION="ifup" INTERFACE="$config" DEVICE="$iface" PROTO=plugif /sbin/hotplug-call "iface" &
}


#===  FUNCTION  ================================================================
#          NAME:  stop_interface_plugif
#   DESCRIPTION:  
#    PARAMETERS:  
#       RETURNS:  
#===============================================================================

stop_interface_plugif() {
  local config="$1"
  local ifname=
  
  env -i ACTION="predown" INTERFACE="$config" DEVICE="$iface" PROTO=plugif /sbin/hotplug-call "services" &

  #Remove from firewall config.
  $DEBUG unset_fwzone "$config"
  $DEBUG /etc/init.d/firewall restart

  #Reset network and udhcpc state.
  local ifname
  config_get ifname "$config" ifname

  local lock="/var/lock/dhcp-${ifname}"
  [ -f "$lock" ] && lock -u "$lock"

  remove_dns "$config"

  local pidfile="/var/run/dhcp-${ifname}.pid"
  local pid="$(cat "$pidfile" 2>/dev/null)"
  [ -d "/proc/$pid" ] && {
    grep -qs udhcpc "/proc/$pid/cmdline" && $DEBUG kill -TERM $pid && \
      while grep -qs udhcpc "/proc/$pid/cmdline"; do sleep 1; done
    $DEBUG rm -f "$pidfile"
  }

  uci -P /var/state revert "network.$config"
  
  env -i ACTION="ifdown" INTERFACE="$config" DEVICE="$iface" PROTO=plugif /sbin/hotplug-call "iface" &
}