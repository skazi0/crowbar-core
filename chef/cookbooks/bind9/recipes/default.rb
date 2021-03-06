# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "utils"
require "ipaddr"

package "bind9" do
  case node[:platform_family]
  when "rhel", "suse"
    package_name "bind"
  end
  action :install
end
package "bind9utils" do
  case node[:platform_family]
  when "rhel", "suse"
    package_name "bind-utils"
  end
  action :install
end

case node[:platform_family]
when "debian"
  binduser = "bind"
  bindgroup = "bind"
when "rhel", "suse"
  binduser = "named"
  bindgroup = "named"
end

directory "/etc/bind" do
  owner "root"
  group bindgroup
  mode 0775
  action :create
end

unless node[:dns][:master]
  directory "/etc/bind/slave" do
    owner binduser
    group bindgroup
    mode 0755
    action :create
  end
end

node.set[:dns][:zone_files]=Array.new

def populate_soa(zone, old_zone = nil)
  defaults = {
    admin: "support.#{node[:fqdn]}.",
    ttl: "1h",
    serial: Time.now.to_i,
    slave_refresh: "12h",
    slave_retry: "180",
    slave_expire: "8w",
    negative_cache: "300"
  }

  defaults.keys.each do |k|
    zone[k] ||= old_zone[k] unless old_zone.nil?
    zone[k] ||= defaults[k]
  end

  zone
end
def make_zone(zone)
  # copy over SOA records that we have not overridden
  populate_soa zone
  zonefile_entries=Array.new
  Chef::Log.debug "Processing zone: #{zone.inspect}"
  # Arrange for the forward lookup zone to be created.
  template "/etc/bind/db.#{zone[:domain]}" do
    source "db.erb"
    mode 0644
    owner "root"
    group "root"
    notifies :reload, "service[bind9]"
    variables(zone: zone)
    only_if { node[:dns][:master] }
  end
  zonefile_entries << zone[:domain]

  # Arrange for reverse lookup zones to be created.
  # Since there is no elegant method for doing this that takes into account
  # CIDR or IPv6, do it the excessively ugly way and create one zone per IP.
  hostsprocessed={}
  zone[:hosts].keys.sort.each do |hostname|
    host=zone[:hosts][hostname]
    [:ip4addr, :ip6addr].each do |addr|
      next unless host[addr]
      next if hostsprocessed[host[addr]]
      hostsprocessed[host[addr]]=1
      rev_zone=Mash.new
      populate_soa rev_zone, zone
      rev_domain=IPAddr.new(host[addr]).reverse
      rev_zone[:domain] = rev_domain
      rev_zone[:nameservers] = zone[:nameservers]
      rev_zone[:hosts] = Mash.new
      rev_zone[:hosts]["#{rev_domain}."] = Mash.new
      rev_zone[:hosts]["#{rev_domain}."][:pointer]= if hostname == "@"
                                                      "#{zone[:domain]}."
                                                    else
                                                      "#{hostname}.#{zone[:domain]}."
                                                    end
      Chef::Log.debug "Processing zone: #{rev_zone.inspect}"
      template "/etc/bind/db.#{rev_domain}" do
        source "db.erb"
        mode 0644
        owner "root"
        group "root"
        notifies :reload, "service[bind9]"
        variables(zone: rev_zone)
        only_if { node[:dns][:master] }
      end
      zonefile_entries << rev_domain
    end
  end

  if node[:dns][:master]
    master_ip = nil
  else
    master_ip = node[:dns][:master_ip]
  end

  admin_addr = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address

  Chef::Log.debug "Creating zone file for zones: #{zonefile_entries.inspect}"
  template "/etc/bind/zone.#{zone[:domain]}" do
    source "zone.erb"
    mode 0644
    owner "root"
    group "root"
    notifies :reload, "service[bind9]"
    variables(zonefile_entries: zonefile_entries,
              master_ip: master_ip,
              admin_addr: admin_addr)
  end
  node.set[:dns][:zone_files] << "/etc/bind/zone.#{zone[:domain]}"

  zonefile_entries
end

# Create our basic zone infrastructure.
zones = Mash.new

localhost_zone = Mash.new
localhost_zone[:domain] = "localhost"
prev_localhost_zone = node[:dns][:zones]["localhost"] rescue nil
populate_soa(localhost_zone, prev_localhost_zone )
localhost_zone[:nameservers] = ["#{node[:fqdn]}."]
localhost_zone[:hosts] = Mash.new
localhost_zone[:hosts]["@"] = Mash.new
localhost_zone[:hosts]["@"][:ip4addr] = "127.0.0.1"
localhost_zone[:hosts]["@"][:ip6addr] = "::1"
unless prev_localhost_zone.nil?
  if prev_localhost_zone.to_hash != localhost_zone.to_hash
    localhost_zone[:serial] = Time.now.to_i
  end
end
zones["localhost"] = localhost_zone

cluster_zone = Mash.new
cluster_zone[:domain] = node[:dns][:domain]
prev_cluster_zone = node[:dns][:zones][node[:dns][:domain]] rescue nil
populate_soa(cluster_zone, prev_cluster_zone)
cluster_zone[:nameservers] = ["#{node[:fqdn]}."]
if node[:dns][:master] and not node[:dns][:slave_names].nil?
  node[:dns][:slave_names].each do |slave|
    cluster_zone[:nameservers] << "#{slave}."
  end
end
cluster_zone[:hosts] = Mash.new
# As DHCP addresses can be re-used, we make sure to use the one node which is
# the most recent; this requires two passes
temporary_dhcp = {}
# Get the list of nodes
nodes = node_search_with_cache("*:*")
fqdns = []
nodes.each do |n|
  fqdns.push(n[:fqdn])
  cname = n["crowbar"]["display"]["alias"] rescue nil
  cname = nil unless cname && ! cname.empty?
  base_name_no_net = n[:fqdn].chomp(".#{node[:dns][:domain]}")
  alias_name_no_net = cname unless base_name_no_net == cname

  Chef::Recipe::Barclamp::Inventory.list_networks(n).each do |network|
    next unless network.address
    if network.name == "admin"
      base_name = base_name_no_net
      alias_name = alias_name_no_net
    else
      net_name = network.name.gsub("_","-")
      base_name = "#{net_name}-#{base_name_no_net}"
      alias_name = "#{net_name}-#{alias_name_no_net}" if alias_name_no_net
    end
    cluster_zone[:hosts][base_name] = Mash.new
    cluster_zone[:hosts][base_name][:ip4addr] = network.address
    cluster_zone[:hosts][base_name][:alias] = alias_name if alias_name

    # add legacy entry for network.domain (in addition to network-domain)
    unless network.name == "admin"
      base_name = "#{net_name}.#{base_name_no_net}"
      alias_name = "#{net_name}.#{alias_name_no_net}" if alias_name_no_net
      cluster_zone[:hosts][base_name] = Mash.new
      cluster_zone[:hosts][base_name][:ip4addr] = network.address
      cluster_zone[:hosts][base_name][:alias] = alias_name if alias_name
    end
  end

  # Also set DNS name with temporary DHCP address for discovered nodes
  if n[:state] == "discovered" &&
      !cluster_zone[:hosts].key?(base_name_no_net) &&
      Chef::Recipe::Barclamp::Inventory.get_network_by_type(n, "admin").nil?
    address = n[:ipaddress]
    if address.nil?
      # no ohai can result in this
      Chef::Log.warn("#{n[:hostname]} in discovered state has no IP address (missing ohai data?); not adding to DNS zone")
      next
    end
    time = n[:ohai_time]
    use_temporary = true

    unless temporary_dhcp[address].nil?
      temp_time, _temp_base_name, _temp_alias_name = temporary_dhcp[address]
      use_temporary = false if time < temp_time
    end

    if use_temporary
      temporary_dhcp[address] = [time, base_name_no_net, alias_name_no_net]
    end
  end
end

temporary_dhcp.each_pair do |address, value|
  _, base_name, alias_name = value
  cluster_zone[:hosts][base_name] = Mash.new
  cluster_zone[:hosts][base_name][:ip4addr] = address
  cluster_zone[:hosts][base_name][:alias] = alias_name if alias_name
end

# let's create records for allocated addresses which do not belong to a node
search(:crowbar, "id:*_network").each do |network|
  #this is not network, or at least there is no nodes
  next unless network.key?("allocated_by_name")
  net_name=network[:id].gsub(/_network$/, "").gsub("_","-")
  network[:allocated_by_name].each_key do |host|
    if !host.match(/.#{node[:dns][:domain]}$/) || fqdns.include?(host)
      # this is node in crowbar terms or it not belong to our domain, so lets skip it
      next
    end
    base_name=host.chomp(".#{node[:dns][:domain]}")
    unless net_name == "admin"
      base_name="#{net_name}-#{base_name}"
    end
    cluster_zone[:hosts][base_name] = Mash.new
    cluster_zone[:hosts][base_name][:ip4addr] = network[:allocated_by_name][host][:address]

    # add legacy entry for network.domain (in addition to network-domain)
    unless net_name == "admin"
      base_name = host.chomp(".#{node[:dns][:domain]}")
      base_name = "#{net_name}.#{base_name}"
      cluster_zone[:hosts][base_name] = Mash.new
      cluster_zone[:hosts][base_name][:ip4addr] = network[:allocated_by_name][host][:address]
    end
  end
end

if node[:dns][:records].nil?
  cluster_zone[:records] = {}
else
  # we do not want a reference to the chef attribute (since we will save this as an attribute)
  cluster_zone[:records] = node[:dns][:records].to_hash
end

unless prev_cluster_zone.nil?
  if prev_cluster_zone.to_hash != cluster_zone.to_hash
    cluster_zone[:serial] = Time.now.to_i
  end
end

zones[node[:dns][:domain]] = cluster_zone

case node[:platform_family]
when "rhel"
  template "/etc/sysconfig/named" do
    source "redhat-sysconfig-named.erb"
    mode 0644
    owner "root"
    variables options: { "OPTIONS" => "-c /etc/bind/named.conf" }
  end
when "suse"
  template "/etc/sysconfig/named" do
    source "suse-sysconfig-named.erb"
    mode 0644
    owner "root"
    variables options: { "NAMED_ARGS" => "-c /etc/bind/named.conf" }
  end
end

# We would like to bind service only to ip address from admin network unless enable_designate is
# enabled. In which case bind both the admin _and_ public.
admin_network = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin")
admin_addr = admin_network.address

# Load up our default zones.  These never change.
if node[:dns][:master]
  files=%w{db.0 db.255 named.conf.default-zones}
  master_ip = nil
else
  files=%w{named.conf.default-zones}
  master_ip = node[:dns][:master_ip]
end
files.each do |file|
  template "/etc/bind/#{file}" do
    source "#{file}.erb"
    mode 0644
    owner "root"
    group bindgroup
    variables(master_ip: master_ip,
              admin_addr: admin_addr)
    notifies :reload, "service[bind9]"
  end
end

# If we don't have a local named.conf.local, create one.
# We keep this around to let local users add stuff to
# DNS that Crowbar will not manage.

bash "/etc/bind/named.conf.local" do
  code "touch /etc/bind/named.conf.local"
  not_if { ::File.exists? "/etc/bind/named.conf.local" }
end

# Write out the zone databases that Crowbar will be responsible for.
entries = ["0", "255"] # see default zones that never change
zones.keys.sort.each do |zone|
  entries << make_zone(zones[zone])
end

# Drop files that are not used anymore (forgotten nodes, deallocated IP, etc.)
entries.flatten!
db_files = Dir.glob("/etc/bind/db.*")
db_files.each do |db_file|
  entry = db_file["/etc/bind/db.".length..-1]
  next if entries.include?(entry)

  file db_file do
    action :delete
  end
end

# Update named.conf.crowbar to include the new zones.
template "/etc/bind/named.conf.crowbar" do
  source "named.conf.crowbar.erb"
  mode 0644
  owner "root"
  group bindgroup
  variables(zonefiles: node[:dns][:zone_files])
  notifies :reload, "service[bind9]"
end

if node[:dns][:enable_designate]
  template "/etc/named.d/designate-rndc-access.conf" do
    source "designate-rndc-access.conf.erb"
    mode 0o640
    owner "root"
    group bindgroup
    variables(
      rndc_key: node[:dns][:designate_rndc_key],
      admin_ip: admin_network.address,
      admin_subnet: IP::IP4.netmask_to_subnet(admin_network.netmask),
      admin_network: admin_network.subnet
    )
    notifies :restart, "service[bind9]", :delayed
  end
end

if node[:dns][:master]
  allow_transfer = node[:dns][:allow_transfer].to_a + node[:dns][:slave_ips].to_a
  allow_transfer = allow_transfer.uniq.sort.compact.delete_if { |n| n.empty? }
else
  allow_transfer = []
end

# When we're restoring the admin node from backup or upgrade data,
# reject incoming DNS traffic to avoid sending wrong results to running
# clients.
if node["crowbar"]["admin_node"] && ::File.exist?("/var/lib/crowbar/install/disable_dns")
  admin_addr = "127.0.0.1"
  service "stop dnsmasq during restore" do
    service_name "dnsmasq"
    action [:stop, :disable]
  end
end

### FIXME Change to "any" once IPv6 support has been implemented
admin_addr6 = "none"
public_addr6 = "none"
if node[:dns][:enable_designate] && !node[:dns][:master]
  node[:dns][:forwarders].push master_ip
end

ipaddresses = [admin_addr]
ip6addresses = [admin_addr6]
if node[:dns][:enable_designate]
  public_addr = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "public").address
  public_addr = nil if admin_addr == public_addr
  ipaddresses << public_addr unless public_addr.nil?
  ip6addresses << public_addr6 unless public_addr6 == "none"
end

# Rewrite our default configuration file
template "/etc/bind/named.conf" do
  source "named.conf.erb"
  mode 0644
  owner "root"
  group bindgroup
  variables(forwarders: node[:dns][:forwarders],
            allow_transfer: allow_transfer,
            ipaddresses: ipaddresses,
            ip6addresses: ip6addresses,
            enable_designate: node[:dns][:enable_designate]
           )
  notifies :restart, "service[bind9]", :immediately
end

service "bind9" do
  case node[:platform_family]
  when "rhel", "suse"
    service_name "named"
  end
  supports restart: true, status: true, reload: true
  action [:enable, :start]
end
utils_systemd_service_restart "bind9"

execute "reload nscd after dns config change" do
  command "nscd -i hosts"
  action :nothing
  subscribes :run, "template[/etc/bind/db.#{node[:dns][:domain]}]"
  only_if { File.exist?("/var/run/nscd/nscd.pid") }
end

node.set[:dns][:zones]=zones
include_recipe "resolver"
