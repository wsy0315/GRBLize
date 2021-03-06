unit import_files;

interface
uses
  SysUtils, StrUtils, Windows, Classes, Forms, Controls, Menus,
  Math, StdCtrls, Graphics, FileCtrl, Dialogs, Clipper;

const
  c_hpgl_scale = 40;
  c_numOfFiles = 8 -1;
  c_numOfPens = 32 -1;

  type

  Thpgl_cmd = (cmd_none, cmd_pa, cmd_pu, cmd_pd, cmd_sp, cmd_in,
              cmd_number, cmd_drill, cmd_exit, cmd_nextline);
  Taction = (none, lift, seek, mill, drill);
  Tshape = (online, inside, outside, pocket, drillhole);
  Trotate = (deg0, deg90, deg180, deg270);

  TpointFloat = record
    X: Double;
    Y: Double;
  end;

  Tbounds = record
    min: TIntPoint;
    max: TIntPoint;
    mid: TIntPoint;
  end;

  Tfile_param = record
    valid: boolean;
    enable: boolean;
    penoverride: Integer;
    rotate: Trotate;
    mirror: Boolean;
    scale: Double;
    isdrillfile:Boolean;
    bounds: Tbounds;
    offset: TintPoint;
  end;

  Tpen_record = record
    used: boolean;
    enable: boolean;
    shape: Tshape;
    color: TColor;
    diameter: Double;
    offset: TIntPoint;    // in HPGL Plotter units 40/mm
    scale: Double;
    speed: Integer;
    z_end: Double;
    z_inc: Double;
  end;

  Tblock_record = record
    enable: boolean;
    pen: Integer;
    fileID: Integer;
    closed: boolean;    // closed Polygon (TRUE) oder offener Linienpfad (FALSE)
    isChild: boolean;  // hat einen Parent
    parentID: Integer;  // -1 wenn kein Parent gefunden, sonst Block-#
    isParent: boolean;  // hat eine ChildList
    childList: Array of Integer;
    bounds: Tbounds;
    outline_raw: Tpath;   // outline path original (Integer Points)
    outline: Tpath;       // skaliert und mit Offsets
  end;

  Tfinal = record
    enable: Boolean;
    pen: Integer;
    shape: Tshape;
    closed: Boolean;
    bounds: Tbounds;
    outlines: Tpaths;
    millings: Tpaths;
  end;

  Tjob = record
    fileDelimStrings: Array[0..c_numOfFiles] of String[255];
    pens: Array[0..31] of Tpen_record;
    partsize_x: Double;
    partsize_y: Double;
    partsize_z: Double;
    z_penlift: Double;
    z_penup: Double;
    z_gauge: Double;
    z_feedmult: Double;
    cam_x: Double;
    cam_y: Double;
    cam_z: Double;
    park_x: Double;
    park_y: Double;
    park_z: Double;
    toolchange_x: Double;
    toolchange_y: Double;
    toolchange_z: Double;
    probe_x: Double;
    probe_y: Double;
    probe_z: Double;
    invert_z: Boolean;
    parkposition_on_end: Boolean;
    toolchange_pause: Boolean;
    use_excellon_dia: Boolean;
    optimize_drills: Boolean;
    use_probe: Boolean;
  end;

const
  ActionArray: Array [0..4] of String[7] =
   ('none', 'lift', 'seek', 'drill', 'mill');
  ShapeArray: Array [0..4] of String[15] =
   ('CONTOUR', 'INSIDE', 'OUTSIDE', 'POCKET', 'DRILL');
  ShapeColorArray: Array [0..4] of Tcolor =
   (clBlack, clBlue, clRed, clFuchsia, clgreen);

  zeroPoint: TIntPoint = (
    X: 0;
    Y: 0;
    );

  PenInit: Tpen_record = (
      used: false;
      enable: false;
      shape: online;
      color: clblack;
      diameter: 0.0;
      scale: 100;
      speed: 400;
      z_end: 0.3;
      z_inc: 1.0;
    );

  BlockZeroEntry: Tblock_record =
    ( enable: false;
      pen: -1;
      fileID: 0;
      closed: false;
      isChild: false;
      parentID: -1;
      isParent: false;
      );

var
  job: Tjob;
  use_inches_in_drillfile: Boolean;
  FileParamArray: Array[0..c_numOfFiles] of Tfile_param;
  blockArrays: Array [0..c_numOfFiles] of Array of Tblock_record;

  final_array: Array of Tfinal;


  ToolCursor: TIntpoint; // in HPGL-Units
  ToolCursorBlock: Integer;
  CurrentPen, PendingPen: Integer;
  LastAction, PendingAction: Taction;
  CurrentBlockID,
  CurrentfileID: Integer;
  Last_z: Double;
  LastPoint: TIntPoint;
  FileIndex: Integer;

  procedure init_blockArrays;
  function point_in_bounds(my_point: TIntPoint; my_bounds: Tbounds): Boolean;
  function bounds_in_bounds(my_bounds1, my_bounds2: Tbounds): Boolean;
  procedure hpgl_fileload(my_name:String; fileID, penOverride: Integer);
  procedure drill_fileload(my_name:String; fileID, penOverride: Integer; useDrillDia: Boolean);
  procedure param_change;
  procedure item_change(arr_idx: Integer);

  function FloatToStrDot(my_val: Double):String;
  function StrDotToFloat(my_str: String): Double;

  // sucht in Array my_path nach Punkt mit geringstem Abstand zu last_xy
  function find_nearest_point(var search_path: Tpath; last_x, last_y: Integer): Integer;

implementation

function FloatToStrDot(my_val: Double):String;
var
  my_Settings: TFormatSettings;
begin
  GetLocaleFormatSettings(GetUserDefaultLCID, my_Settings);
  my_Settings.DecimalSeparator := '.';
  FloatToStrDot:= FormatFloat('0.00',my_val,my_Settings);
end;

function StrDotToFloat(my_str: String): Double;
var
  my_Settings: TFormatSettings;
begin
  GetLocaleFormatSettings(GetUserDefaultLCID, my_Settings);
  my_Settings.DecimalSeparator := '.';
  StrDotToFloat:= StrToFloat(my_str,my_Settings);
end;

// #############################################################################
// #############################################################################

procedure init_blockArrays;
var i: Integer;
begin
  CurrentBlockID:= 0;
  for i := 0 to c_numOfFiles do begin
    SetLength(blockArrays[i], 0);
  end;
end;

function new_block(fileID: Integer): Integer;
// h�ngt leeren Block an
var my_len: Integer;
begin
  my_len:= length(blockArrays[fileID]);
  SetLength(blockArrays[fileID], my_len+1);
  blockArrays[fileID,my_len]:= BlockZeroEntry;
  SetLength(blockArrays[fileID,my_len].outline_raw, 0);
  SetLength(blockArrays[fileID,my_len].outline, 0);
  new_block:= my_len;
end;

procedure append_point(fileID, blockID: Integer; new_pt: TintPoint);
// f�r File-Import:
// h�ngt �bergebenen Punkt an Block-Pfad an und setzt File-Bounds
var my_len: Integer;
begin
  my_len:= length(blockArrays[fileID, blockID].outline_raw);

  // Skalierung und Offsets des Files
  new_pt.X:= FileParamArray[fileID].offset.x
    + (round(new_pt.X * 10 * FileParamArray[fileID].scale) div 1000);
  new_pt.Y:= FileParamArray[fileID].offset.y
    + (round(new_pt.Y * 10 * FileParamArray[fileID].scale) div 1000);

  // Bounds des Files neu setzen
  if new_pt.X < FileParamArray[fileID].bounds.min.x then
    FileParamArray[fileID].bounds.min.x:= new_pt.X;
  if new_pt.X > FileParamArray[fileID].bounds.max.x then
    FileParamArray[fileID].bounds.max.x:= new_pt.X;

  if new_pt.Y < FileParamArray[fileID].bounds.min.y then
    FileParamArray[fileID].bounds.min.y:= new_pt.Y;
  if new_pt.Y > FileParamArray[fileID].bounds.max.y then
    FileParamArray[fileID].bounds.max.y:= new_pt.Y;

  // Bounds des Blocks neu setzen
  if new_pt.X < blockArrays[fileID, blockID].bounds.min.x then
    blockArrays[fileID, blockID].bounds.min.x:= new_pt.X;
  if new_pt.X > blockArrays[fileID, blockID].bounds.max.x then
    blockArrays[fileID, blockID].bounds.max.x:= new_pt.X;

  if new_pt.Y < blockArrays[fileID, blockID].bounds.min.y then
    blockArrays[fileID, blockID].bounds.min.y:= new_pt.Y;
  if new_pt.Y > FileParamArray[fileID].bounds.max.y then
    blockArrays[fileID, blockID].bounds.max.y:= new_pt.Y;

  // Raw-Points bereits mit File-Offset/Scale
  SetLength(blockArrays[fileID, blockID].outline_raw, my_len+1);
  blockArrays[fileID, blockID].outline_raw[my_len]:= new_pt;
  SetLength(blockArrays[fileID, blockID].outline, my_len+1);
  blockArrays[fileID, blockID].outline[my_len]:= new_pt;
end;

// #############################################################################

procedure file_rotate_mirror(fileID: Integer);
// Jeden Block pr�fen, ob geschlossener Pfad; danach outline_raw-Pfade
// rotieren und spiegeln
// Verwendet beim Import gesetzte File-Bounds
// muss gleich nach Import geschehen
var b,p, my_pathlen, my_blocklen: Integer;
  nx, ny: Integer;
  my_file_entry: Tfile_param;
  my_pt, my_first_pt, my_last_pt: TIntPoint;

begin
  my_file_entry:= FileParamArray[fileID];
  if not my_file_entry.valid then
    exit;
  my_blocklen:= length(blockArrays[fileID]);
  if my_blocklen = 0 then // keine Bl�cke enthalten
    exit;
  for b:= 0 to my_blocklen - 1 do begin
    my_pathlen:= length(blockArrays[fileID, b].outline_raw);
    if my_pathlen = 0 then  // keine Pfade enthalten
      continue;

    // letzten Eintrag entfernen, falls gleich erstem Punkt, daf�r "closed" setzen
    my_first_pt:= blockArrays[fileID,b].outline_raw[0];
    my_last_pt:= blockArrays[fileID,b].outline_raw[my_pathlen-1];
    if (my_first_pt.X = my_last_pt.X) and (my_first_pt.Y = my_last_pt.Y) then begin
      dec(my_pathlen);
      blockArrays[fileID,b].closed:= true;
      setlength(blockArrays[fileID,b].outline_raw, my_pathlen);
      setlength(blockArrays[fileID,b].outline, my_pathlen);
    end else
      blockArrays[fileID,b].closed:= false;

    if (not my_file_entry.mirror) and (my_file_entry.rotate = deg0) then
      continue;

    for p:= 0 to my_pathlen - 1 do begin
      my_pt:= blockArrays[fileID, b].outline_raw[p];
      nx:= my_file_entry.bounds.min.x + my_file_entry.bounds.max.x - my_pt.X;
      ny:= my_file_entry.bounds.min.y + my_file_entry.bounds.max.y - my_pt.Y;
      if my_file_entry.mirror then
        case my_file_entry.rotate of
          deg0:
            begin
              my_pt.X:= nx;
            end;
          deg90:
            begin // X:=Y, Y:=X, X und Y vertauschen
              ny:= my_pt.Y;
              my_pt.Y := my_pt.X;
              my_pt.X := ny;
            end;
          deg180:
            begin
              my_pt.Y:= ny;
            end;
          deg270:
            begin
              my_pt.X:= ny;
              my_pt.Y:= nx;
            end;
        end
      else
        case my_file_entry.rotate of
          deg90:
            begin
              my_pt.Y:= my_pt.X;
              my_pt.X:= ny;
            end;
          deg180:
            begin
              my_pt.X:= nx;
              my_pt.Y:= ny;
            end;
          deg270:
            begin
              my_pt.X:= my_pt.Y;
              my_pt.Y:= nx;
            end;
        end;  // case
      blockArrays[fileID, b].outline_raw[p]:= my_pt;
    end;      // path
  end;        // blocks
end;

procedure block_scale(fileID, blockID: Integer);
// Block mit Pen-Offsets und Skalierung versehen
var i, my_pen, my_len: Integer;
  my_bounds: Tbounds;
  my_pt: TintPoint;

begin
  if not FileParamArray[fileID].valid then
    exit;
  if length(blockArrays[fileID]) = 0 then
    exit; // kein Block vorhanden
  my_len:= length(blockArrays[fileID,blockID].outline_raw);
  if my_len = 0 then
    exit; // kein Path vorhanden
  my_pen:= blockArrays[fileID, blockID].pen;
  if my_pen < 0 then
    exit; // kein Pen vorhanden

  my_bounds.min.x:= high(Integer);
  my_bounds.min.y:= high(Integer);
  my_bounds.max.x:= low(Integer);
  my_bounds.max.y:= low(Integer);
  for i:= 0 to my_len-1 do begin
    my_pt:= blockArrays[fileID, blockID].outline_raw[i];
    // Skalierung des Blocks
    my_pt.X:= round(my_pt.X * 10 * job.pens[my_pen].scale) div 1000;
    my_pt.Y:= round(my_pt.Y * 10 * job.pens[my_pen].scale) div 1000;

    if my_pt.X < my_bounds.min.x then
      my_bounds.min.x:= my_pt.X;
    if my_pt.X > my_bounds.max.x then
      my_bounds.max.x:= my_pt.X;

    if my_pt.Y < my_bounds.min.y then
      my_bounds.min.y:= my_pt.Y;
    if my_pt.Y > my_bounds.max.y then
      my_bounds.max.y:= my_pt.Y;
    blockArrays[fileID, blockID].outline[i]:= my_pt;
  end;
  blockArrays[fileID, blockID].enable:= FileParamArray[fileID].enable and job.pens[my_pen].enable;
  my_bounds.mid.x:= (my_bounds.min.x + my_bounds.max.x) div 2;
  my_bounds.mid.y:= (my_bounds.min.y + my_bounds.max.y) div 2;
  blockArrays[fileID,blockID].bounds:= my_bounds;

end;

procedure block_scale_file(fileID: Integer);
// skaliert Pens/Tools �ber gesamtes File
var
  my_blockID, my_blockcount: Integer;
begin
  my_blockcount:= length(blockArrays[fileID]);
  if my_blockcount = 0 then
    exit;
  if FileParamArray[fileID].valid then
    for my_blockID:= 0 to my_blockcount - 1 do
      block_scale(fileID, my_blockID);
end;

procedure block_scale_all;
// skaliert Pens/Tools �ber alle Files
var
  i: Integer;
begin
  for i:= 0 to c_numOfFiles do
    block_scale_file(i);
end;

procedure block_scale_pen(penID: Integer);
// skaliert Pens/Tools �ber alle Files
var
  my_fileID, my_blockID, my_blockcount: Integer;
begin
  for my_fileID:= 0 to c_numOfFiles do begin
    my_blockcount:= length(blockArrays[my_fileID]);
    if FileParamArray[my_fileID].valid then
      for my_blockID:= 0 to my_blockcount - 1 do begin
        if blockArrays[my_fileID, my_blockID].pen = penID then
          block_scale(my_fileID, my_blockID);
      end;
  end;
end;

function bounds_in_bounds(my_bounds1, my_bounds2: Tbounds): Boolean;
// liefert TRUE wenn my_bounds1 innerhalb oder auf my_bounds2
begin
  bounds_in_bounds:= false;
  if my_bounds1.min.x < my_bounds2.min.x then
    exit;
  if my_bounds1.min.y < my_bounds2.min.y then
    exit;
  if my_bounds1.max.x > my_bounds2.max.x then
    exit;
  if my_bounds1.max.y > my_bounds2.max.y then
    exit;
  bounds_in_bounds:= true;
end;

function point_in_bounds(my_point: TIntPoint; my_bounds: Tbounds): Boolean;
begin
  point_in_bounds:= false;
  if my_point.x < my_bounds.min.x then
    exit;
  if my_point.x > my_bounds.max.x then
    exit;
  if my_point.y < my_bounds.min.y then
    exit;
  if my_point.y > my_bounds.max.y then
    exit;
  point_in_bounds:= true;
end;

function find_nearest_point(var search_path: Tpath; last_x, last_y: Integer): Integer;
// sucht in Array my_path nach Punkt mit geringstem Abstand zu last_xy
var
  p, temp_idx, lastdv, dv, dx, dy, my_len: Integer;
begin
  my_len:= length(search_path);
  lastdv:= high(Integer);
  temp_idx:= 0;
  for p:= 0 to my_len-1 do begin
    dx:= search_path[p].x;
    dy:= search_path[p].y;
    // ist dieser Punkt ist gleich dem Ausgangspunkt?
    if (dx = last_x) and (dy = last_y) then
      continue; // wenn ja, �berspringen
    // finde n�chstliegenden Punkt
    dx:= abs(dx - last_x); // Abstand zum Ausgangspunkt
    dy:= abs(dy - last_y);
    // dv:= round(sqrt(sqr(dx) + sqr(dy)));
    // schneller und ausreichend: Absolutwerte addieren
    dv:= dx + dy;
    if dv <= lastdv then begin
      temp_idx:= p; // wird "mitgezogen"
      lastdv:= dv;
    end;
  end;
  find_nearest_point:= temp_idx;
end;

// #############################################################################
{$I hpgl_import.inc}
{$I drill_import.inc}
// #############################################################################


procedure add_outline_to_final(my_path: Tpath; my_Idx: Integer);
var my_len: Integer;
begin
  my_len:= length(final_array[my_Idx].outlines);
  setlength(final_array[my_Idx].outlines, my_len+1);
  final_array[my_Idx].outlines[my_len]:= my_path;
end;

function add_block_to_final(my_block: Tblock_record): Integer;
// erzeugt neuen final_array-Eintrag, gibt Index zu neuem final zur�ck
var
  i: Integer;
begin
  i:= length(final_array);
  setlength(final_array, i+1);
  // diese Werte k�nnen nachtr�glich ge�ndert werden:
  final_array[i].shape:= job.pens[my_block.pen].shape;
  // diese Werte liegen seit Import fest:
  final_array[i].enable:= my_block.enable;
  final_array[i].pen:= my_block.pen;
  final_array[i].closed:= my_block.closed;
  final_array[i].bounds:= my_block.bounds;
  
  // ersten Outline-Pfad �bertragen
  setlength(final_array[i].outlines, 1);
  setlength(final_array[i].outlines[0], 1);
  final_array[i].outlines[0]:= my_block.outline;
  add_block_to_final:= i;
end;


procedure make_final_array(fileID: Integer);
// Blocks zusammensuchen, Childs adoptieren
// Ber�cksichtigt nur eine Verwandschaftsebene!
// Tr�gt Werte aus Pen-Array ein
var i, c, p, m: Integer;
  my_len: Integer;
begin
  for p:= 0 to length(blockArrays[fileID])-1 do begin    // Parent-Loop (p)
    if not blockArrays[fileID, p].closed then
      continue;                                 // ist nur eine Linie
    if blockArrays[fileID, p].parentID >= 0 then
      continue;                                 // ist bereits Parent
    if not blockArrays[fileID, p].enable  then
      continue;                               // nicht aktiv

    for c:= 0 to length(blockArrays[fileID])-1 do begin  // Child-Loop (c)
      if p = c then
        continue;                               // sind wir selbst
      if not blockArrays[fileID, c].enable  then
        continue;                               // nicht aktiv
      if blockArrays[fileID,c].pen <> blockArrays[fileID,p].pen then
        continue;                               // nicht mein Pen
      if not blockArrays[fileID,c].closed then
        continue;                               // ist nur eine Linie
      if blockArrays[fileID,c].parentID >= 0 then       // ist bereits Parent
        continue;
      if not bounds_in_bounds(blockArrays[fileID,c].bounds, blockArrays[fileID,p].bounds) then
        continue;   // Child ist nicht in Parent-Bounds

      // ist Outline von Block [k] in Outline von Block [i] enthalten?
      // if PointInPolygon (blockArray[c].bounds.mid, blockArray[p].outline) <> 0 then begin
        blockArrays[fileID,c].parentID:= p;
        blockArrays[fileID,c].isChild:= true;
        // Parent setzen
        my_len:= length(blockArrays[fileID,p].childList);
        setlength(blockArrays[fileID,p].childList, my_len+1);
        blockArrays[fileID,p].childList[my_len]:= c;
        blockArrays[fileID,p].isParent:= true;
     // end;
    end;
  end;

  for p:= 0 to length(blockArrays[fileID])-1 do begin
    if not blockArrays[fileID,p].closed then begin
      add_block_to_final(blockArrays[fileID,p]);     // ist nur eine Linie
      continue;
    end;
    if not blockArrays[fileID,p].isChild then begin  // ist ersteinmal kein Child
      m:= add_block_to_final(blockArrays[fileID,p]); // also hinzuf�gen
      if blockArrays[fileID,p].isParent then         // hat Block Childs?
        for i:= 0 to length(blockArrays[fileID,p].childList)-1 do begin  // Child-Loop (c)
          c:= blockArrays[fileID,p].childList[i];
          add_outline_to_final(blockArrays[fileID,c].outline, m);
        end;
    end;
  end;
end;

// #############################################################################
// #############################################################################
// CLIPPER tools
// #############################################################################
// #############################################################################


procedure compile_milling(var my_final_entry: Tfinal);
// Wrapper f�r ClipperOffset f�r einazelnen Pen, mehrere Blocks
// erstellt milling-Paths-Array mit ggf. mehreren Pfadgruppen
// Milling-Pfade [0] sind immer outline

var i, j, rp, mp: Integer;
  my_radius, my_dia: Double;
  result_paths: Tpaths;
  my_poly_end: TEndType;
  my_cclw: boolean;

begin
  if my_final_entry.closed then begin
    my_cclw:= Orientation(my_final_entry.outlines[0]); // parent CCLW?
    if not my_cclw then
      for i:= 0 to length(my_final_entry.outlines)-1 do
        my_final_entry.outlines[i]:= ReversePath(my_final_entry.outlines[i]);
  end;

  if (my_final_entry.shape = drillhole) or (not my_final_entry.closed) then begin
    my_final_entry.millings:= my_final_entry.outlines;
    exit;
  end;

  my_radius:= job.pens[my_final_entry.pen].diameter * 20;  // = mm * 40plu / 2
  case my_final_entry.shape of
    inside, pocket:
      my_radius:= -my_radius;
    online, drillhole:
      begin
        my_final_entry.millings:= my_final_entry.outlines;
        exit;
      end;
  end;
  my_dia:= job.pens[my_final_entry.pen].diameter/2;
  with TClipperOffset.Create() do
  try
    Clear;
    ArcTolerance:= round(my_radius) div 20 + 1;
    if my_final_entry.closed then
      my_poly_end:= etClosedPolygon
    else
      my_poly_end:= etOpenRound;

    AddPaths(my_final_entry.outlines, jtRound, my_poly_end);
    Execute(result_paths, my_radius);
    my_final_entry.millings:= CleanPolygons(result_paths, my_dia);

    if my_final_entry.shape = pocket then begin
      my_radius:= my_radius + 5;
      if abs(my_radius) < 20 then // 0,5 mm
        my_radius:= -20;
      for i:= 0 to 99 do begin
        Clear;
        AddPaths(result_paths, jtRound, my_poly_end);
        Execute(result_paths, my_radius);
        if length(result_paths) = 0 then
          break;
        rp:= length(result_paths);
        mp:= length(my_final_entry.millings);
        setlength(my_final_entry.millings, mp + rp);
        for j:= 0 to rp-1 do
          my_final_entry.millings[mp+j]:= CleanPolygon(result_paths[j], my_dia);
      end;
    end;
  finally
    Free;
  end;
end;

// #############################################################################
// #############################################################################


procedure param_change;
// alle �nderungen, Offset etc.
var i: Integer;
begin
  block_scale_all;
  setlength(final_array, 0);
  for i:= 0 to c_numOfFiles do
    if FileParamArray[i].valid then
      make_final_array(i);
  // Werkzeugkorrektur-Offsets f�r fertiges BlockArray
  for i:= 0 to high(final_array) do
    compile_milling(final_array[i]);
end;

procedure item_change(arr_idx: Integer);
// Parameter-�nderungen in Final-Array anwenden
begin
  if (arr_idx < length(final_array)) and (arr_idx >= 0) then
    compile_milling(final_array[arr_idx]);
end;


end.

