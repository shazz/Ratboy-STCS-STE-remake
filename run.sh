echo Building code
/home/matt/projects/MJJ/bin/vasm/vasmm68k_mot -Ftos -quiet -spaces -I src -I . -o build/AUTO/STRGOOSE.PRG src/main.s

echo starting hatari
hatari --machine ste --memsize 1 --tos /home/matt/projects/MJJ/bin/hatari/TOS/tos162fr.img --harddrive /home/matt/projects/MJJ/build --fast-boot on --confirm-quit off

# --zoom 1.0 --max-width 320 --max-height 200