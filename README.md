# transparentProxy
Takes a Linux Install (currently only Ubuntu 16.04) from stock to the latest tor with transparent proxy routing. 

Use at your own risk...

This is a BASH script that simply automates the many networking steps to take a fresh install
and make it route ALL traffic over TOR. 

Be sure that you understand what this means before you use this script. 

There are many implications of doing this, some of them are:
- Download / Upload speeds will be incredibly slow
- You will find yourself doing Captch responses quite a bit
- ping (and any other ICMP packets) will not function
- Many sites will think that you are in a random country that is not your own, so language settings might be wrong. 
- You can fix this by limiting the exit node for tor to use.
- Edit /usr/local/etc/tor/torrc and add the following to the end
```
ExitNodes {us},{gb}
```
You can add as many countries as you like there. Note that this does make you easier to trace.
