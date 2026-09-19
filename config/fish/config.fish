source /usr/share/cachyos-fish-config/cachyos-config.fish

# overwrite greeting
# potentially disabling fastfetch
#function fish_greeting
#    # smth smth
#end
# overwrite greeting
# overwrite greeting
function fish_greeting
    pokemon-colorscripts -b -r > /tmp/pokemon-logo.txt
    fastfetch --logo-type file --logo /tmp/pokemon-logo.txt
end
