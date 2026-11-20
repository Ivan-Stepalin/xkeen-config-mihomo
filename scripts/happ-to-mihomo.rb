#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Конвертирует подписку YouNet в формате Happ JSON (User-Agent: Happ/1.0)
# в список proxies: для mihomo (включая транзитные мосты bridge-1/bridge-2
# и игровые серверы Hysteria2, которые не отдаются обычному User-Agent mihomo).

require "json"
require "yaml"
require "open3"

ROOT = File.expand_path("..", __dir__)
SECRETS = File.join(ROOT, ".secrets.yaml")

def convert_happ_json(raw_json)
  items = JSON.parse(raw_json)
  proxies = []
  seen_names = Hash.new(0)

  items.each do |item|
    base_name = (item["remarks"] || item["name"] || "").strip
    # Пропускаем сводные авто-балансировщики Happ (они дублируют узлы стран)
    next if base_name.empty?
    next if base_name =~ /Самый быстрый|Белые списки \(авто\)|Авто \(Telegram\)|Белые списки \(резерв\)/

    outbounds = (item["outbounds"] || []).reject { |o| %w[freedom blackhole dns].include?(o["protocol"]) }
    outbounds.each do |ob|
      tag = ob["tag"].to_s
      suffix =
        if tag =~ /bridge-(\d+)/
          " (мост #{$1})"
        elsif tag =~ /se2-2/
          " #2"
        else
          ""
        end
      name = "#{base_name}#{suffix}"
      seen_names[name] += 1
      name = "#{name} (#{seen_names[name]})" if seen_names[name] > 1

      proto = ob["protocol"]
      stream = ob["streamSettings"] || {}
      sec = stream["security"].to_s

      if proto == "vless"
        vnext = (ob.dig("settings", "vnext") || []).first
        next unless vnext
        user = (vnext["users"] || []).first || {}
        net = stream["network"].to_s
        net = "tcp" if net.empty? || net == "raw"

        p = {
          "name" => name,
          "type" => "vless",
          "server" => vnext["address"],
          "port" => vnext["port"].to_i,
          "uuid" => user["id"],
          "udp" => true,
          "packet-encoding" => "xudp",
          "network" => net
        }
        flow = user["flow"].to_s
        p["flow"] = flow unless flow.empty?

        if sec == "reality"
          r = stream["realitySettings"] || {}
          p["tls"] = true
          p["servername"] = r["serverName"] if r["serverName"]
          p["client-fingerprint"] = (r["fingerprint"].to_s.empty? ? "firefox" : r["fingerprint"])
          p["reality-opts"] = {
            "public-key" => r["publicKey"].to_s,
            "short-id" => r["shortId"].to_s
          }
        elsif sec == "tls"
          t = stream["tlsSettings"] || {}
          p["tls"] = true
          p["servername"] = t["serverName"] if t["serverName"] && !t["serverName"].empty?
          p["client-fingerprint"] = (t["fingerprint"].to_s.empty? ? "firefox" : t["fingerprint"])
          p["alpn"] = t["alpn"] if t["alpn"].is_a?(Array) && !t["alpn"].empty?
        end

        if net == "xhttp"
          xh = stream["xhttpSettings"] || {}
          opts = {}
          opts["path"] = xh["path"] if xh["path"] && !xh["path"].empty?
          opts["host"] = xh["host"] if xh["host"] && !xh["host"].empty?
          opts["mode"] = xh["mode"] if xh["mode"] && !xh["mode"].empty?
          p["xhttp-opts"] = opts unless opts.empty?
        end

        proxies << p
      elsif proto == "hysteria"
        s = ob["settings"] || {}
        hy = stream["hysteriaSettings"] || {}
        t = stream["tlsSettings"] || {}
        next unless s["address"] && s["port"]

        p = {
          "name" => name,
          "type" => "hysteria2",
          "server" => s["address"],
          "port" => s["port"].to_i,
          "password" => hy["auth"].to_s,
          "sni" => t["serverName"].to_s,
          "udp" => true
        }
        p["alpn"] = t["alpn"] if t["alpn"].is_a?(Array) && !t["alpn"].empty?
        p["client-fingerprint"] = t["fingerprint"] if t["fingerprint"] && !t["fingerprint"].empty?
        proxies << p
      end
    end
  end

  { "proxies" => proxies }.to_yaml
end

if __FILE__ == $PROGRAM_NAME
  if ARGV[0] == "--serve"
    require "socket"
    port = (ARGV[1] || 8389).to_i
    server = TCPServer.new("0.0.0.0", port)
    $stdout.sync = true
    puts "younet-sub listening on 0.0.0.0:#{port}"
    loop do
      client = server.accept
      Thread.new(client) do |sock|
        begin
          req = sock.gets
          while (line = sock.gets) && line != "\r\n"; end
          sec = File.exist?(SECRETS) ? (YAML.load_file(SECRETS) || {}) : {}
          url = sec["SUB_YOUNET"]
          out, status = Open3.capture2("curl", "-s", "-L", "-m", "15", "-A", "Happ/1.0", url.to_s)
          if status.success? && !out.empty?
            body = convert_happ_json(out)
            sock.print "HTTP/1.1 200 OK\r\nContent-Type: text/yaml; charset=utf-8\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
          else
            sock.print "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n"
          end
        rescue StandardError => e
          warn "error: #{e.message}"
        ensure
          sock.close rescue nil
        end
      end
    end
  else
    url = ARGV[0]
    if !url && File.exist?(SECRETS)
      sec = YAML.load_file(SECRETS) || {}
      url = sec["SUB_YOUNET"] || sec["SUB_1"]
    end
    abort "Usage: happ-to-mihomo.rb <url> | --serve [port]" unless url
    out, status = Open3.capture2("curl", "-s", "-L", "-m", "15", "-A", "Happ/1.0", url)
    abort "curl failed" unless status.success? && !out.empty?
    puts convert_happ_json(out)
  end
end
