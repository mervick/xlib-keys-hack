xlib-keys-hack
==============

- Simulation of pressing `Escape` key when press `Caps Lock` key without any combos;
- Simulation of pressing and holding third-level modificator by `Left Alt + Caps Lock`
  and simulation of releasing of this key by `Right Alt`;
- Simulation of pressing real `Caps Lock` by `Caps Lock + Enter`
  (because `Caps Lock` used as additional `Left Ctrl`);
- Simulation of pressing real `Enter` by `Enter` key
  (because `Enter` key used as additional `Right Ctrl`);
- Notifying my XMobar FIFO PIPE about third-level modificator, `Num Lock` and `Caps Lock`
  state to make indicators of these on panel
  ([see here for more details](https://github.com/unclechu/xmonadrc/blob/master/xmobar-cmd.sh)).

Build
-----

```bash
$ make
```

Run (as daemon)
---------------

```bash
$ ./build/xlib-keys-hack
```

Author
------

[Viacheslav Lotsmanov](https://github.com/unclechu)

License
-------

[GNU/GPLv3](./LICENSE)
