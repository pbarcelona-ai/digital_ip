# package files  
  ppm_io_pkg.sv 
  golden_model_pkg.sv
  ../rtl/vision_system_pkg.sv
  ../rtl/distortion_model_pkg.sv

# IP files
  ../ip/fixed_recip/fixed_recip.sv 
  ../ip/coord_gen/coord_gen.sv
  ../ip/bilinear/bilinear.sv 
  ../ip/bicubic/bicubic.sv 
  ../ip/frame_buffer/frame_buffer.sv
  ../rtl/axis_in_ctrl.sv 
  ../rtl/axis_out_ctrl.sv 
  ../rtl/axi_lite_regs.sv

# top-level files
  ../rtl/vision_system.sv

# testbench files
  tb_vision_system.sv
