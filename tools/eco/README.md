# tools/eco: ECO tăng dần sau route

Các script ở đây sửa layout đã route của IP `gemm_ip` mà không route lại toàn bộ. Luồng đi qua ba chặng:

1. **OpenLane 1.0.2** chạy flow như cũ, ra DEF cuối, netlist, SDC và SPEF signoff.
2. **OpenROAD của LibreLane 3.0.16** đọc DEF đó, sửa tăng dần (chèn diode, đổi cỡ cell, chèn buffer), rồi route lại chỉ các net bị đụng.
3. **OpenLane 1.0.2** nhập DEF đã sửa để kiểm lại: ARC antenna, trích RC, STA, Magic DRC và LVS.

OpenLane 1.0.2 không có detailed route tăng dần. Mỗi vòng ECO của nó route lại cả chip và sinh vi phạm mới (xem `docs/TIEN_DO_SIGNOFF.md`). OpenROAD mới thì giữ nguyên các net còn dây: ở chế độ `RipUpMode::INCR`, router coi dây cũ là vật cản cố định và chỉ route những net đã mất dây.

## Phiên bản

| Thành phần | Phiên bản |
|---|---|
| LibreLane | 3.0.16 (stable, 2026-10-06) |
| Image LibreLane (amd64) | `ghcr.io/librelane/librelane@sha256:4bc9042ba177f73f275b5b39e7d372a07d3f4043f548a0ba7f640097b7205051` |
| OpenROAD trong image | `dcf36133a369abc8f3c5e5738cd4d82e4903c0e0` (2026-02-17) |
| OpenLane 1.0.2 | `ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64` (OpenROAD 41a51eaf) |

PDK, tech LEF, LEF và lib luôn lấy từ PDK của OpenLane 1.0.2 (`$PDK_ROOT`), không dùng PDK đi kèm image mới.

## Biến môi trường

Mọi script đọc `env.sh`:

| Biến | Ý nghĩa |
|---|---|
| `ECO_DIR` | thư mục làm việc, chứa mọi đầu vào và đầu ra |
| `PDK_ROOT` | PDK của flow OpenLane 1.0.2 (có `sky130A/` bên dưới) |
| `OL` | thư mục OpenLane 1.0.2 (`flow.tcl`, `designs/`), cho `ol.sh` |
| `LIBRELANE_IMAGE`, `OL_IMAGE` | mặc định là hai image ở trên |
| `DOCKER_MEMORY`, `DOCKER_SWAP` | giới hạn RAM container, mặc định `10g` / `40g` |
| `V3R_ODB` | ODB của run gốc, chỉ dùng khi so timing (`sta6b.sh`) |

Chuẩn bị `ECO_DIR` từ run OpenLane gốc:

    $ECO_DIR/in/GEMM_top.round1.def         DEF cuối của run gốc
    $ECO_DIR/in/GEMM_top.sdc                SDC signoff (tự đứng, sau CTS)
    $ECO_DIR/in/GEMM_top.{min,nom,max}.spef SPEF signoff (để so)
    $ECO_DIR/lef/{ProcessingElementRow,sram_antenna,GemmAxiShell_antenna}.lef
    $ECO_DIR/lib/{ProcessingElementRow,GemmAxiShell}.lib

## Các script

| Nhóm | Script |
|---|---|
| Chạy container | `nor.sh` (OpenROAD mới; Tcl, hoặc Python qua `openroad -python`), `olor.sh` (OpenROAD của OL1, cho `drv_plan.tcl`), `ol.sh` (OpenLane 1.0.2, chế độ interactive), `watch.sh` (dừng container khi log có lỗi hoặc ổ dưới 10 GB) |
| Thiết lập chung | `common.tcl` (LEF, `route_setup` theo ip_v3r, `ant_count`) |
| Guide từ dây | `mkguide.py` (dựng route guide từ dây và via trong DEF, có nối các mảnh chỉ liền nhau qua chân cell), `guide_pins_all.tcl` + `guide_pincheck.py` (mọi chân nằm trong guide), `guide_conn.py` (guide liền mạch) |
| So DEF | `defgeo.py` (hình học từng net), `defsum.py`, `defcmp.py` (số net bị route lại), `compcheck.py` (cell không phải filler có bị dời không) |
| Kiểm khớp | `s3_roundtrip.tcl` (đọc rồi ghi DEF, kiểm antenna), `s4b_check.tcl` (nạp guide, ECO rỗng) |
| ECO antenna | `s4c_round.py` (danh sách đích theo margin, gỡ filler cục bộ, `repair_antennas` → `detailed_route` → `filler_placement` → nối nguồn), `s4c_try.sh` / `s6c_ant.sh` (thử ±15 µm, rồi ±30 µm, rồi `remove_fillers`) |
| Đổi cỡ, buffer | `s6a_resize.py` (đổi cỡ cell nhận), `s6a_buffer.py` (buffer phía sink, kèm đo slack trước và sau) |
| ECO DRV và hold | `drv_plan.tcl` (lập kế hoạch ở SS RC max: thử đổi cỡ bằng `replace_cell`), `drv_pick.py` (chọn cỡ buffer theo bảng lib SS), `s6c_eco.py` (áp: đổi cỡ, buffer ở driver hoặc chân dout, buffer phía sink cho hold) |
| Kiểm trong OL1 | `s5_ol.tcl` (chế độ `arc`, `rcx`, `full`, `lvs`, `final`), `spot_check.sh` (Magic drc(full) trên cửa sổ cố định của GDS, view đầy đủ của macro) |
| STA và DRV | `sta6b.tcl` (setup/hold theo loại path, DRV theo giới hạn lib), `sta6b_one.sh`, `sta6b.sh`, `sta_table.py` |

## Thứ tự chạy

Ví dụ dưới đây giả định đã `export ECO_DIR PDK_ROOT OL`, và `T` là đường dẫn tới `tools/eco`.

1. Dựng guide và kiểm. Một DEF không mang route guide, mà `repair_antennas` cần guide của mọi net nhiều chân:

       python3 $T/mkguide.py $ECO_DIR/in/GEMM_top.round1.def $PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef \
           $ECO_DIR/s4a/round1.guide $ECO_DIR/s4a/stats.txt
       python3 $T/guide_conn.py $ECO_DIR/s4a/round1.guide
       $T/nor.sh gp $T/guide_pins_all.tcl $ECO_DIR/s4a/pins.log DEF=$ECO_DIR/in/GEMM_top.round1.def OUTF=$ECO_DIR/s4a/pins_all.tsv
       $T/nor.sh s4b $T/s4b_check.tcl $ECO_DIR/s4b/s4b.log GUIDE=$ECO_DIR/s4a/round1.guide OUTD=s4b

   Kiểm tra: DEF ghi lại phải giống hệt DEF vào; ECO rỗng không được route lại net nào ngoài các chỗ DRT mới tự sửa.

2. ECO antenna, tối đa 3 lượt:

       $T/s4c_try.sh 1 $ECO_DIR/in/GEMM_top.round1.def $ECO_DIR/s4a/round1.guide

   Sau mỗi lượt, so DEF:

       python3 $T/defgeo.py <DEF ra> <ra>.geo.tsv
       python3 $T/defcmp.py <vào>.geo.tsv <ra>.geo.tsv
       python3 $T/compcheck.py <vào>.geo.tsv <ra>.geo.tsv

3. Nhập vào OL1 và kiểm:

       $T/ol.sh s5 $T/s5_ol.tcl $ECO_DIR/s5/arc.log S5_DEF=<DEF> S5_TAG=<tag> S5_MODE=arc

4. ECO DRV. Lập kế hoạch trên ODB và SPEF RC max do OL1 trích, rồi áp:

       $T/olor.sh plan $T/drv_plan.tcl $ECO_DIR/s6c/c1.plan.log ROUND=c1 NETS=<danh sách net vượt lib> \
           ODB=<run OL1>/results/routing/GEMM_top.odb SPEF=<run OL1>/results/routing/mca/process_corner_max/GEMM_top.spef \
           "DONT_USE=<DONT_USE_CELLS của config>"
       python3 $T/drv_pick.py $ECO_DIR/s6c/c1.plan_raw.tsv $ECO_DIR/s6c/c1.plan.tsv
       $T/nor.sh eco $T/s6c_eco.py $ECO_DIR/s6c/c1.eco.log IN=<DEF> GUIDE=<guide của DEF> OUT=s6c/c1 PLAN=$ECO_DIR/s6c/c1.plan.tsv

   Sau mỗi lượt: `ol.sh` với `S5_MODE=rcx`, rồi `sta6b_one.sh` cho layout mới.

5. ECO hold: một dòng `SINKBUF` trong plan, ví dụ `dlygate4sd3_1+buf_4` trước chân SRAM. Sau đó chạy lại vòng antenna (`s6c_ant.sh`) cho các net mới.

6. Kiểm cuối: `ol.sh` với `S5_MODE=final` (ARC, RCX, STA, Magic GDS và DRC, SPICE, LVS), rồi `magic_macro_check.sh` và `spot_check.sh` cho các chỗ cần xem bằng view đầy đủ của macro.

## Những điều cần biết về OpenROAD dcf3613

- `repair_antennas` crash nếu một net nhiều chân không có guide. Lỗi nằm ở `ant/src/WireBuilder.cc`: `dbNetIsLocal` lấy phần tử đầu của danh sách guide mà không kiểm danh sách có rỗng không.
- Không được gắn guide cho net một chân. DRT luôn báo DRT-0222 cho các net này, vì `GuidePathFinder` không duyệt lượt nào với net một chân.
- Không chạy OpenRCX trong cùng tiến trình trước DRT. RCX sắp xếp lại dbWire và để lại đoạn chéo, làm DRT báo lỗi DRT-1010.
- ODB do bản này ghi ra sau khi tạo net bằng Python có thể không đọc lại được. Các script trao đổi bằng DEF và dựng lại guide cho mỗi lượt.
- Trên layout đã lấp kín filler, phải gỡ filler quanh chỗ cần chèn cell (`CORE_SPACER`, cửa sổ ±15 µm) trước khi chèn, và lấp lại sau DRT bằng đúng danh sách cell của OL1.
- Trên layout gốc, DRT mới tự sửa 3 chỗ Metal Spacing mà DRT của OL1 không báo. Ba chỗ này đã được kiểm bằng Magic.
