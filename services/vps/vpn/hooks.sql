UPDATE hooks_table SET
  post_up = post_up || ' iptables -t nat -A PREROUTING ! -i wg0 -p tcp --dport 8000 -j DNAT --to-destination 10.8.0.3:8000; iptables -t nat -A PREROUTING ! -i wg0 -p udp --dport 7000 -j DNAT --to-destination 10.8.0.3:7000; iptables -t nat -A POSTROUTING -o wg0 -d 10.8.0.3 ! -s 10.8.0.0/24 -j MASQUERADE;',
  post_down = post_down || ' iptables -t nat -D PREROUTING ! -i wg0 -p tcp --dport 8000 -j DNAT --to-destination 10.8.0.3:8000; iptables -t nat -D PREROUTING ! -i wg0 -p udp --dport 7000 -j DNAT --to-destination 10.8.0.3:7000; iptables -t nat -D POSTROUTING -o wg0 -d 10.8.0.3 ! -s 10.8.0.0/24 -j MASQUERADE;',
  updated_at = CURRENT_TIMESTAMP
WHERE id = 'wg0' AND post_up NOT LIKE '%10.8.0.3:8000%';
