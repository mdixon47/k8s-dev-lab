# -*- mode: ruby -*-
# Local Kubernetes dev lab: 1 control plane + 2 workers on VirtualBox (kubeadm)
K8S_VERSION = "1.30"
# ubuntu/jammy64 is amd64-only; on Apple Silicon (VirtualBox 7.1+) use the arm64 build of bento's box.
HOST_ARM64  = RUBY_PLATFORM.match?(/arm64|aarch64/)
BOX         = ENV.fetch("K8S_BOX", HOST_ARM64 ? "bento/ubuntu-22.04" : "ubuntu/jammy64")
NET_PREFIX  = "192.168.56"
POD_CIDR    = "10.244.0.0/16"
# On arm64 the stock 22.04 kernel leaves the VirtualBox console window blank; install the
# HWE kernel so it shows a login prompt (see scripts/console-kernel.sh). Costs one reboot
# per node during provisioning. Override with K8S_CONSOLE_KERNEL=0|1.
CONSOLE_KERNEL = ENV.fetch("K8S_CONSOLE_KERNEL", HOST_ARM64 ? "1" : "0") == "1"
# Node that gets an XFCE desktop for learning/sandboxing (scripts/desktop.sh); it is sized up
# to DESKTOP_MEM/DESKTOP_CPUS. Set K8S_DESKTOP="" for no desktop or name another node.
DESKTOP_NODE = ENV.fetch("K8S_DESKTOP", "cp1")
DESKTOP_MEM  = 4096
DESKTOP_CPUS = 4
# Vagrant boots every VM headless. K8S_GUI=1 opens the VirtualBox window for the desktop node,
# K8S_GUI=all for every node, K8S_GUI=cp1,w1 for a list. Close windows with "Continue running
# in background"; "Power off" halts the node (vagrant up <node> recovers it).
GUI_NODES = case ENV.fetch("K8S_GUI", "")
            when ""    then []
            when "1"   then [DESKTOP_NODE]
            when "all" then :all
            else ENV["K8S_GUI"].split(",").map(&:strip)
            end

NODES = [
  { name: "cp1", ip: "#{NET_PREFIX}.10", cpus: 2, mem: 2048, role: "control-plane" },
  { name: "w1",  ip: "#{NET_PREFIX}.11", cpus: 2, mem: 2048, role: "worker" },
  { name: "w2",  ip: "#{NET_PREFIX}.12", cpus: 2, mem: 2048, role: "worker" },
  # "web": standalone edge box, NOT in the cluster. nginx proxies /api/ to the workers' NodePort.
  { name: "web", ip: "#{NET_PREFIX}.20", cpus: 1, mem: 1024, role: "web" },
]
WORKER_IPS = NODES.select { |n| n[:role] == "worker" }.map { |n| n[:ip] }.join(" ")

Vagrant.configure("2") do |config|
  config.vm.box = BOX
  config.vm.box_check_update = false
  config.vm.synced_folder ".", "/vagrant"

  # /etc/hosts entries so nodes resolve each other by name
  hosts = NODES.map { |n| "#{n[:ip]} #{n[:name]}" }.join("\n")

  NODES.each do |node|
    config.vm.define node[:name] do |vm|
      vm.vm.hostname = node[:name]
      vm.vm.network "private_network", ip: node[:ip]

      desktop = node[:name] == DESKTOP_NODE

      vm.vm.provider "virtualbox" do |vb|
        vb.name   = "k8s-#{node[:name]}"
        vb.gui    = GUI_NODES == :all || GUI_NODES.include?(node[:name])
        vb.cpus   = desktop ? [node[:cpus], DESKTOP_CPUS].max : node[:cpus]
        vb.memory = desktop ? [node[:mem], DESKTOP_MEM].max : node[:mem]
        vb.customize ["modifyvm", :id, "--nested-hw-virt", "on"] unless HOST_ARM64
        vb.customize ["modifyvm", :id, "--clipboard-mode", "bidirectional"] if desktop
        # the ramfb display cannot resize; stop the GUI from asking (it blanks the desktop)
        vb.customize ["setextradata", :id, "GUI/AutoresizeGuest", "off"] if desktop
      end

      vm.vm.provision "hosts", type: "shell",
        inline: "grep -q ' #{node[:name]}$' /etc/hosts || echo -e '#{hosts}' >> /etc/hosts"
      if CONSOLE_KERNEL
        vm.vm.provision "console-kernel", type: "shell", path: "scripts/console-kernel.sh", reboot: true
      end
      vm.vm.provision "banner", type: "shell", path: "scripts/console-banner.sh"

      case node[:role]
      when "control-plane", "worker"
        vm.vm.provision "common", type: "shell", path: "scripts/common.sh",
          env: { "K8S_VERSION" => K8S_VERSION, "NODE_IP" => node[:ip] }
        if node[:role] == "control-plane"
          vm.vm.provision "control-plane", type: "shell", path: "scripts/control-plane.sh",
            env: { "NODE_IP" => node[:ip], "POD_CIDR" => POD_CIDR }
        else
          vm.vm.provision "worker", type: "shell", path: "scripts/worker.sh"
        end
      when "web"
        vm.vm.provision "web", type: "shell", path: "scripts/web.sh",
          env: { "WORKERS" => WORKER_IPS, "NODE_PORT" => "30080", "SITE_PORT" => "30081" }
      else
        raise "unknown role #{node[:role]} for node #{node[:name]}"
      end

      # Last, so the cluster is up before the (slow) desktop install starts
      vm.vm.provision "desktop", type: "shell", path: "scripts/desktop.sh" if desktop
    end
  end
end
