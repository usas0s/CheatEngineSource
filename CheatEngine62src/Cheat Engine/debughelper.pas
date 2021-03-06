unit DebugHelper;

{$mode DELPHI}

interface

uses
  Windows, Classes, SysUtils, Controls, forms, syncobjs, guisafecriticalsection, Dialogs,
  foundcodeunit, debugeventhandler, cefuncproc, newkernelhandler, comctrls,
  debuggertypedefinitions, formChangedAddresses, frmTracerUnit, KernelDebuggerInterface, VEHDebugger,
  WindowsDebugger, debuggerinterfaceAPIWrapper, debuggerinterface,symbolhandler;



type
  TDebuggerthread = class(TThread)
  private
    eventhandler: TDebugEventHandler;
    ThreadList: TList; //only the debugger thread can add or remove from this list
    BreakpointList: TList; //only the main thread can add or remove from this list
    breakpointCS: TGuiSafeCriticalSection;
    ThreadListCS: TGuiSafeCriticalSection; //must never be locked before breakpointCS
    OnAttachEvent: Tevent; //event that gets set when a process has been created
    OnContinueEvent: TEvent; //event that gets set by the user when he/she wants to continue from a break

    //settings
    handlebreakpoints: boolean;
    hidedebugger: boolean;
    canusedebugregs: boolean;

    createProcess: boolean;

    fNeedsToSetEntryPointBreakpoint: boolean;
    filename,parameters: string;


    fcurrentThread: TDebugThreadHandler;
    globalDebug: boolean; //kernelmode debugger only

    fRunning: boolean;
    procedure cleanupDeletedBreakpoints;
    function getDebugThreadHanderFromThreadID(tid: dword): TDebugThreadHandler;

    procedure GetBreakpointList(address: uint_ptr; size: integer; var bplist: TBreakpointSplitArray);
    procedure defaultConstructorcode;
    procedure lockSettings;
    procedure WaitTillAttachedOrError;
    procedure setCurrentThread(x: TDebugThreadHandler);
    function getCurrentThread: TDebugThreadHandler;
    procedure FindCodeByBP(address: uint_ptr; size: integer; bpt: TBreakpointTrigger);

    function AddBreakpoint(owner: PBreakpoint; address: uint_ptr; bpt: TBreakpointTrigger; bpm: TBreakpointMethod; bpa: TBreakpointAction; debugregister: integer=-1; debugregistersize: integer=0; foundcodedialog: Tfoundcodedialog=nil; threadID: dword=0; frmchangedaddresses: Tfrmchangedaddresses=nil; FrmTracer: TFrmTracer=nil; tcount: integer=0; changereg: pregistermodificationBP=nil): PBreakpoint;




  public
    InitialBreakpointTriggered: boolean; //set by a debugthread when the first unknown exception is dealth with causing all subsequent unexpected breakpoitns to become unhandled

    procedure SetBreakpoint(breakpoint: PBreakpoint; UpdateForOneThread: TDebugThreadHandler=nil);
    procedure UnsetBreakpoint(breakpoint: PBreakpoint; specificContext: PContext=nil);


    function lockThreadlist: TList;
    procedure unlockThreadlist;

    procedure lockbplist;
    procedure unlockbplist;

    procedure updatebplist(lv: TListview; showshadow: boolean);
    procedure setbreakpointcondition(bp: PBreakpoint; easymode: boolean; script: string);
    function getbreakpointcondition(bp: PBreakpoint; var easymode: boolean):pchar;

    function  isBreakpoint(address: uint_ptr; address2: uint_ptr=0; includeinactive: boolean=false): PBreakpoint;
    function  CodeFinderStop(codefinder: TFoundCodeDialog): boolean;
    function  setChangeRegBreakpoint(regmod: PRegisterModificationBP): PBreakpoint;
    procedure setBreakAndTraceBreakpoint(frmTracer: TFrmTracer; address: ptrUint; BreakpointTrigger: TBreakpointTrigger; bpsize: integer; count: integer; condition:string='');
    function  stopBreakAndTrace(frmTracer: TFrmTracer): boolean;
    procedure FindWhatCodeAccesses(address: uint_ptr);
    function  FindWhatCodeAccessesStop(frmchangedaddresses: Tfrmchangedaddresses): boolean;
    procedure FindWhatAccesses(address: uint_ptr; size: integer);
    procedure FindWhatWrites(address: uint_ptr; size: integer);
    function  SetOnWriteBreakpoint(address: ptrUint; size: integer; tid: dword=0): PBreakpoint;
    function  SetOnAccessBreakpoint(address: ptrUint; size: integer; tid: dword=0): PBreakpoint;
    function  SetOnExecuteBreakpoint(address: ptrUint; askforsoftwarebp: boolean = false; tid: dword=0): PBreakpoint;
    function  ToggleOnExecuteBreakpoint(address: ptrUint; tid: dword=0): PBreakpoint;

    procedure UpdateDebugRegisterBreakpointsForThread(thread: TDebugThreadHandler);
    procedure RemoveBreakpoint(breakpoint: PBreakpoint);
    function GetUsableDebugRegister: integer;

    procedure ContinueDebugging(continueOption: TContinueOption; runtillAddress: ptrUint=0);

    procedure SetEntryPointBreakpoint;


    constructor MyCreate2(filename: string; parameters: string; breakonentry: boolean=true); overload;
    constructor MyCreate2(processID: THandle); overload;
    destructor Destroy; override;

    function isWaitingToContinue: boolean;

    function getrealbyte(address: ptrUint): byte;

    property CurrentThread: TDebugThreadHandler read getCurrentThread write setCurrentThread;
    property NeedsToSetEntryPointBreakpoint: boolean read fNeedsToSetEntryPointBreakpoint;
    property running: boolean read fRunning;

    procedure Terminate;
    procedure Execute; override;
  end;

var
  debuggerthread: TDebuggerthread = nil;



implementation

uses cedebugger, kerneldebugger, formsettingsunit, FormDebugStringsUnit,
     frmBreakpointlistunit, plugin, memorybrowserformunit, autoassembler, pluginexports;

//-----------Inside thread code---------

resourcestring
  rsDebuggerCrash = 'Debugger Crash';
  rsCreateProcessFailed = 'CreateProcess failed:%s';

  rsOnlyTheDebuggerThreadIsAllowedToSetTheCurrentThread = 'Only the debugger '
    +'thread is allowed to set the current thread';
  rsUnreadableAddress = 'Unreadable address';
  rsDebuggerInterfaceDoesNotSupportSoftwareBreakpoints = 'Debugger interface %'
    +'s does not support software breakpoints';
  rsAddBreakpointAnInvalidDebugRegisterIsUsed = 'AddBreakpoint: An invalid '
    +'debug register is used';
  rsAll4DebugRegistersAreCurrentlyUsedUpFreeOneAndTryA = 'All 4 debug '
    +'registers are currently used up. Free one and try again';
  rsTheFollowingOpcodesAccessed = 'The following opcodes accessed %s';
  rsTheFollowingOpcodesWriteTo = 'The following opcodes write to %s';
  rsAllDebugRegistersAreUsedUpDoYouWantToUseASoftwareBP = 'All debug '
    +'registers are used up. Do you want to use a software breakpoint?';
  rsAllDebugRegistersAreUsedUp = 'All debug registers are used up';
  rsYes = 'Yes';
  rsNo = 'No';
  rsOutOfHWBreakpoints = 'All debug registers are used up and this debugger '
    +'interface does not support software Breakpoints. Remove some and try '
    +'again';
  rsUnreadableMemoryUnableToSetSoftwareBreakpoint = 'Unreadable memory. '
    +'Unable to set software breakpoint';
  rsDebuggerFailedToAttach = 'Debugger failed to attach';
  rsThisDebuggerInterfaceDoesnTSupportBreakOnEntryYet = 'This debugger '
    +'interface :''%s'' doesn''t support Break On Entry yet';


procedure TDebuggerthread.Execute;
var
  debugEvent: _Debug_EVENT;
  debugging: boolean;
  currentprocesid: dword;
  ContinueStatus: dword;
  startupinfo: windows.STARTUPINFO;
  processinfo: windows.PROCESS_INFORMATION;
  dwCreationFlags: dword;
  error: integer;

  code,data: ptrUint;
  s: tstringlist;
  allocs: TCEAllocarray;

begin
  if terminated then exit;

  try
    try
      currentprocesid := 0;
      DebugSetProcessKillOnExit(False); //do not kill the attached processes on exit



      if createprocess then
      begin
        dwCreationFlags:=DEBUG_PROCESS or DEBUG_ONLY_THIS_PROCESS;

        zeromemory(@startupinfo,sizeof(startupinfo));
        zeromemory(@processinfo,sizeof(processinfo));

        GetStartupInfo(@startupinfo);




        if windows.CreateProcess(
          pchar(filename),
          pchar('"'+filename+'" '+parameters),
          nil, //lpProcessAttributes
          nil, //lpThreadAttributes
          false, //bInheritHandles
          dwCreationFlags,
          nil, //lpEnvironment
          pchar(extractfilepath(filename)), //lpCurrentDirectory
          @startupinfo, //lpStartupInfo
          @processinfo //lpProcessInformation
        ) =false then
        begin
          error:=getlasterror;
          MessageBox(0, pchar(Format(rsCreateProcessFailed, [inttostr(error)])
            ), pchar(rsDebuggerCrash), MB_ICONERROR or mb_ok);
          exit;
        end;


        processhandler.processid:=processinfo.dwProcessId;
        Open_Process;
        symhandler.reinitialize;

        closehandle(processinfo.hProcess);
      end else
      begin
        fNeedsToSetEntryPointBreakpoint:=false; //just be sure
        if not DebugActiveProcess(processid) then
          exit;
      end;

      currentprocesid := processid;

      debugging := True;



      while (not terminated) and debugging do
      begin
        if WaitForDebugEvent(debugEvent, 100) then
        begin
          ContinueStatus:=DBG_CONTINUE;
          debugging := eventhandler.HandleDebugEvent(debugEvent, ContinueStatus);

          if debugging then
          begin
            //check if something else has to happen (e.g: wait for user input)

            ContinueDebugEvent(debugEvent.dwProcessId, debugevent.dwThreadId, ContinueStatus);
          end;



        end
        else
        begin
          {
          no event has happened, for 100 miliseconds
          Do some maintenance in here
          }
          //remove the breakpoints that have been unset and are marked for deletion
          cleanupDeletedBreakpoints;
        end;
      end;

    except
      on e: exception do
        messagebox(0, pchar(rsDebuggerCrash+':'+e.message), '', 0);
    end;

  finally
    outputdebugstring('End of debugger');
    if currentprocesid <> 0 then
      debuggerinterfaceAPIWrapper.DebugActiveProcessStop(currentprocesid);

    terminate;
    OnAttachEvent.SetEvent;
  end;

  //end of the routine has been reached (only possingle on terminate, one of debug or exception)

end;

//-----------(mostly) Out of thread code---------

procedure TDebuggerThread.terminate;
var i: integer;
begin
  //remove all breakpoints
  breakpointcs.enter;
  try
    for i:=0 to BreakpointList.Count-1 do
      RemoveBreakpoint(PBreakpoint(BreakpointList[i]));

  finally
    breakpointcs.leave;
  end;

  //tell all events to stop waiting and continue the debug loop. (that now has no breakpoints set)
  ContinueDebugging(co_run);

  fRunning:=false;
  inherited terminate; //and the normal terminate telling the thread to stop


end;

procedure TDebuggerThread.cleanupDeletedBreakpoints;
{
remove the breakpoints that have been unset and are marked for deletion
that can be done safely since this routine is only called when no debug event has
happened, and the breakpoints have already been disabled
}
var
  i: integer;
  bp: PBreakpoint;
  deleted: boolean;
begin
  deleted:=false;
  i:=0;

  breakpointCS.enter;
  try
    while i < Breakpointlist.Count do
    begin
      bp:=PBreakpoint(breakpointlist[i]);
      if bp.markedfordeletion then
      begin
        if bp.referencecount=0 then
        begin
          if not bp.active then
          begin
            if bp.deletecountdown=0 then
            begin
              outputdebugstring('cleanupDeletedBreakpoints: deleting bp');
              breakpointlist.Delete(i);

              if bp.conditonalbreakpoint.script<>nil then
                StrDispose(bp.conditonalbreakpoint.script);

              if bp.traceendcondition<>nil then
                Strdispose(bp.traceendcondition);

              freemem(bp);

              deleted:=true;
            end else dec(bp.deletecountdown);
          end
          else
          begin
            //Some douche forgot to disable it first, waste of processing cycle
            UnsetBreakpoint(bp);
            bp.deletecountdown:=10;

            Inc(i);
          end;
        end;
      end
      else
        Inc(i);
    end;
  finally
    breakpointCS.leave;
  end;

  if deleted and (frmBreakpointlist<>nil) then
    postmessage(frmBreakpointlist.handle, WM_BPUPDATE,0,0); //tell the breakpointlist that there's been an update
end;




procedure TDebuggerThread.setCurrentThread(x: TDebugThreadHandler);
begin
  //no critical sections for the set and getcurrenthread.
  //routines that call this only call it when the debugger is already paused
  if GetCurrentThreadId <> self.ThreadID then
    raise Exception.Create(
      rsOnlyTheDebuggerThreadIsAllowedToSetTheCurrentThread);

  fCurrentthread := x;
end;

function TDebuggerThread.getCurrentThread: TDebugThreadHandler;
begin
  Result := fcurrentThread;
end;

function TDebuggerThread.isWaitingToContinue: boolean;
begin
  result:=(CurrentThread<>nil) and (currentthread.isWaitingToContinue);
end;

procedure TDebuggerThread.lockBPList;
begin
  breakpointCS.enter;
end;

procedure TDebuggerThread.unlockBPList;
begin
  breakpointCS.leave;
end;


function TDebuggerThread.lockThreadlist: TList;
//called from main thread
begin
  BreakpointCS.enter;
  ThreadListCS.enter;
  result:=threadlist;
end;

procedure TDebuggerThread.unlockThreadlist;
begin
  ThreadListCS.leave;
  BreakpointCS.leave;
end;

function TDebuggerThread.getDebugThreadHanderFromThreadID(tid: dword): TDebugThreadHandler;
var
  i: integer;
begin
  breakpointCS.Enter;
  try
    for i := 0 to threadlist.Count - 1 do
      if TDebugThreadHandler(threadlist.items[i]).ThreadId = tid then
      begin
        Result := TDebugThreadHandler(threadlist.items[i]);
        break;
      end;

  finally
    breakpointCS.Leave;
  end;
end;

procedure TDebuggerThread.UpdateDebugRegisterBreakpointsForThread(thread: TDebugThreadHandler);
var i: integer;
begin
  breakpointCS.enter;
  try
    for i:=0 to BreakpointList.count-1 do
      if (PBreakpoint(breakpointlist[i])^.active) and (PBreakpoint(breakpointlist[i])^.breakpointMethod=bpmDebugRegister) then
        SetBreakpoint(PBreakpoint(breakpointlist[i]), thread);
  finally
    breakpointCS.Leave;
  end;
end;

procedure TDebuggerThread.SetBreakpoint(breakpoint: PBreakpoint; UpdateForOneThread: TDebugThreadHandler=nil);
{
Will set the breakpoint.
either by setting the appropriate byte in the code to $cc, or setting the appropriate debug registers the thread(s)
}
var
  Debugregistermask: dword;
  ClearMask: dword; //mask used to whipe the original bits from DR7
  oldprotect, bw: dword;
  currentthread: TDebugThreadHandler;
  i: integer;
begin
  if breakpoint^.breakpointMethod = bpmDebugRegister then
  begin
    //Debug registers
    Debugregistermask := 0;
    outputdebugstring(PChar('1:Debugregistermask=' + inttohex(Debugregistermask, 8)));

    case breakpoint.breakpointTrigger of
      bptWrite: Debugregistermask := $1 or Debugregistermask;
      bptAccess: Debugregistermask := $3 or Debugregistermask;
    end;


    case breakpoint.size of
      2: Debugregistermask := $4 or Debugregistermask;
      4: Debugregistermask := $c or Debugregistermask;
      8: Debugregistermask := $8 or Debugregistermask; //10 is defined as 8 byte
    end;


    outputdebugstring(PChar('2:Debugregistermask=' + inttohex(Debugregistermask, 8)));

    Debugregistermask := (Debugregistermask shl (16 + 4 * breakpoint.debugRegister));
    //set the RWx amd LENx to the proper position
    Debugregistermask := Debugregistermask or (3 shl (breakpoint.debugregister * 2));
    //and set the Lx bit
    Debugregistermask := Debugregistermask or (1 shl 10); //and set bit 10 to 1

    clearmask := (($F shl (16 + 4 * breakpoint.debugRegister)) or (3 shl (breakpoint.debugregister * 2))) xor $FFFFFFFF;
    //create a mask that can be used to undo the old settings

    outputdebugstring(PChar('3:Debugregistermask=' + inttohex(Debugregistermask, 8)));
    outputdebugstring(PChar('clearmask=' + inttohex(clearmask, 8)));

    breakpoint^.active := True;

    if (CurrentDebuggerInterface is TKernelDebugInterface) and globaldebug then
    begin
      //set the breakpoint using globaldebug
      DBKDebug_GD_SetBreakpoint(true, breakpoint.debugregister, breakpoint.address, BreakPointTriggerToBreakType(breakpoint.breakpointTrigger), SizeToBreakLength(breakpoint.size));
    end
    else
    begin
      if (breakpoint.ThreadID <> 0) or (UpdateForOneThread<>nil) then
      begin
        //only one thread
        if updateForOneThread=nil then
          currentthread := getDebugThreadHanderFromThreadID(breakpoint.ThreadID)
        else
          currentthread:=updateForOneThread;

        if currentthread = nil then //thread has been destroyed
          exit;

        currentthread.suspend;
        currentthread.fillContext;
        if BPOverride or ((byte(currentthread.context.Dr7) and byte(Debugregistermask))=0) then
        begin
          case breakpoint.debugregister of
            0: currentthread.context.Dr0 := breakpoint.address;
            1: currentthread.context.Dr1 := breakpoint.address;
            2: currentthread.context.Dr2 := breakpoint.address;
            3: currentthread.context.Dr3 := breakpoint.address;
          end;
          currentthread.DebugRegistersUsedByCE:=currentthread.DebugRegistersUsedByCE or (1 shl breakpoint.debugregister);
          currentthread.context.Dr7 :=(currentthread.context.Dr7 and clearmask) or Debugregistermask;
          currentthread.setContext;
        end;
        currentthread.resume;
      end
      else
      begin
        //update all threads with the new debug register data

        ThreadListCS.enter;
        try
          for i := 0 to ThreadList.Count - 1 do
          begin
            currentthread := threadlist.items[i];
            currentthread.suspend;
            currentthread.fillContext;

            if BPOverride or ((byte(currentthread.context.Dr7) and byte(Debugregistermask))=0) then
            begin
              //make sure this bp spot bp is not used
              case breakpoint.debugregister of
                0: currentthread.context.Dr0 := breakpoint.address;
                1: currentthread.context.Dr1 := breakpoint.address;
                2: currentthread.context.Dr2 := breakpoint.address;
                3: currentthread.context.Dr3 := breakpoint.address;
              end;

              currentthread.DebugRegistersUsedByCE:=currentthread.DebugRegistersUsedByCE or (1 shl breakpoint.debugregister);
              currentthread.context.Dr7 := (currentthread.context.Dr7 and clearmask) or Debugregistermask;
              currentthread.setContext;
            end;
            currentthread.resume;
          end;

        finally
          ThreadListCS.leave;
        end;

      end;

    end;

  end
  else
  begin
    //int3 bp
    breakpoint^.active := True;
    VirtualProtectEx(processhandle, pointer(breakpoint.address), 1, PAGE_EXECUTE_READWRITE, oldprotect);
    WriteProcessMemory(processhandle, pointer(breakpoint.address), @int3byte, 1, bw);
    VirtualProtectEx(processhandle, pointer(breakpoint.address), 1, oldprotect, oldprotect);
  end;

end;

procedure TDebuggerThread.UnsetBreakpoint(breakpoint: PBreakpoint; specificContext: PContext=nil);
var
  Debugregistermask: dword;
  oldprotect, bw: dword;
  ClearMask: dword; //mask used to whipe the original bits from DR7
  currentthread: TDebugThreadHandler;
  i: integer;

  hasoldbp: boolean;
begin
  if breakpoint^.breakpointMethod = bpmDebugRegister then
  begin
    //debug registers
    Debugregistermask := $F shl (16 + 4 * breakpoint.debugRegister) + (3 shl (breakpoint.debugregister * 2));
    Debugregistermask := not Debugregistermask; //inverse the bits


    if (CurrentDebuggerInterface is TKernelDebugInterface) and globaldebug then
    begin
      DBKDebug_GD_SetBreakpoint(false, breakpoint.debugregister, breakpoint.address, BreakPointTriggerToBreakType(breakpoint.breakpointTrigger), SizeToBreakLength(breakpoint.size));
    end
    else
    begin
      if (specificContext<>nil) then
      begin


        case breakpoint.debugregister of
          0: specificContext.Dr0 := 0;
          1: specificContext.Dr1 := 0;
          2: specificContext.Dr2 := 0;
          3: specificContext.Dr3 := 0;
        end;
        specificContext.Dr7 := (specificContext.Dr7 and Debugregistermask);
      end
      else
      if breakpoint.ThreadID <> 0 then
      begin
        //only one thread
        currentthread := getDebugThreadHanderFromThreadID(breakpoint.ThreadID);
        if currentthread = nil then //it's gone
          exit;

        currentthread.suspend;
        currentthread.fillContext;

        //check if this breakpoint was set in this thread
        if (BPOverride) or ((currentthread.DebugRegistersUsedByCE and (1 shl breakpoint.debugregister))>0) then
        begin
          currentthread.DebugRegistersUsedByCE:=currentthread.DebugRegistersUsedByCE and (not (1 shl breakpoint.debugregister));

          case breakpoint.debugregister of
            0: currentthread.context.Dr0 := 0;
            1: currentthread.context.Dr1 := 0;
            2: currentthread.context.Dr2 := 0;
            3: currentthread.context.Dr3 := 0;
          end;
          currentthread.context.Dr7 := (currentthread.context.Dr7 and Debugregistermask);
          currentthread.setContext;

        end;
        currentthread.resume;
      end
      else
      begin
        //do all threads
        begin
          for i := 0 to ThreadList.Count - 1 do
          begin
            currentthread := threadlist.items[i];
            currentthread.suspend;
            currentthread.fillContext;

            hasoldbp:=false; //now check if this thread actually has the breakpoint set (and not replaced or never even set)

            if (BPOverride) or ((currentthread.DebugRegistersUsedByCE and (1 shl breakpoint.debugregister))>0) then
            begin
              currentthread.DebugRegistersUsedByCE:=currentthread.DebugRegistersUsedByCE and (not (1 shl breakpoint.debugregister));

              case breakpoint.debugregister of
                0:
                begin
                  hasoldbp:=currentthread.context.Dr0=breakpoint.address;
                  if hasoldbp then
                    currentthread.context.Dr0 := 0;
                end;

                1:
                begin
                  hasoldbp:=currentthread.context.Dr1=breakpoint.address;
                  if hasoldbp then
                    currentthread.context.Dr1 := 0;
                end;

                2:
                begin
                  hasoldbp:=currentthread.context.Dr2=breakpoint.address;
                  if hasoldbp then
                    currentthread.context.Dr2 := 0;
                end;

                3:
                begin
                  hasoldbp:=currentthread.context.Dr3=breakpoint.address;
                  if hasoldbp then
                    currentthread.context.Dr3 := 0;
                end;
              end;

              if hasoldbp then
              begin
                currentthread.context.Dr7 := (currentthread.context.Dr7 and Debugregistermask);
                currentthread.setcontext;
              end;


            end;
            currentthread.resume;
          end;

        end;
      end;

    end;

  end
  else
  begin
    VirtualProtectEx(processhandle, pointer(breakpoint.address), 1,
      PAGE_EXECUTE_READWRITE,
      oldprotect);
    WriteProcessMemory(processhandle, pointer(breakpoint.address), @breakpoint.originalbyte, 1, bw);
    VirtualProtectEx(processhandle, pointer(breakpoint.address), 1, oldprotect,
      oldprotect);
  end;

  breakpoint^.active := False;
end;

procedure TDebuggerThread.RemoveBreakpoint(breakpoint: PBreakpoint);
var
  i,j: integer;
  bp: PBreakpoint;
begin
  breakpointCS.enter;
  try
    outputdebugstring('RemoveBreakpoint');
    outputdebugstring(PChar('breakpointlist.Count=' + IntToStr(breakpointlist.Count)));

    if breakpoint.owner <> nil then //it's a child, but we need the owner
      breakpoint := breakpoint.owner;


    //clean up all it's children
    for j:=0 to breakpointlist.Count-1 do
    begin
      BP := breakpointlist.items[j];
      if bp.owner = breakpoint then
      begin
        UnsetBreakpoint(bp);
        bp.deletecountdown:=10; //10*100=1000=1 second
        bp.markedfordeletion := True; //set this flag so it gets deleted on next no-event
      end
    end;

    //and finally itself
    UnsetBreakpoint(breakpoint);
    breakpoint.markedfordeletion := True;
    //set this flag so it gets deleted on next no-event

    OutputDebugString('Disabled the breakpoint');
  finally
    breakpointCS.leave;
  end;

  if frmBreakpointlist<>nil then
    postmessage(frmBreakpointlist.handle, WM_BPUPDATE,0,0); //tell the breakpointlist that there's been an update
end;

function TDebuggerThread.AddBreakpoint(owner: PBreakpoint; address: uint_ptr; bpt: TBreakpointTrigger; bpm: TBreakpointMethod; bpa: TBreakpointAction; debugregister: integer=-1; debugregistersize: integer=0; foundcodedialog: Tfoundcodedialog=nil; threadID: dword=0; frmchangedaddresses: Tfrmchangedaddresses=nil; FrmTracer: TFrmTracer=nil; tcount: integer=0; changereg: pregistermodificationBP=nil): PBreakpoint;
var
  newbp: PBreakpoint;
  originalbyte: byte;
  x: dword;
begin
  if bpm=bpmInt3 then
  begin
    if dbcSoftwareBreakpoint in CurrentDebuggerInterface.DebuggerCapabilities then
    begin
      if not ReadProcessMemory(processhandle, pointer(address), @originalbyte,
        1, x) then raise exception.create(rsUnreadableAddress);
    end else raise exception.create(Format(
      rsDebuggerInterfaceDoesNotSupportSoftwareBreakpoints, [
      CurrentDebuggerInterface.name]));

  end
  else
  if bpm=bpmDebugRegister then
  begin
    if (debugregister<0) or (debugregister>3) then raise exception.create(
      rsAddBreakpointAnInvalidDebugRegisterIsUsed);
  end;



  getmem(newbp, sizeof(TBreakPoint));
  ZeroMemory(newbp, sizeof(TBreakPoint));
  newbp^.owner := owner;
  newbp^.address := address;
  newbp^.originalbyte := originalbyte;
  newbp^.breakpointTrigger := bpt;
  newbp^.breakpointMethod := bpm;
  newbp^.breakpointAction := bpa;
  newbp^.debugRegister := debugregister;
  newbp^.size := debugregistersize;
  newbp^.foundcodedialog := foundcodedialog;
  newbp^.ThreadID := threadID;
  newbp^.frmchangedaddresses := frmchangedaddresses;
  newbp^.frmTracer:=frmtracer;
  newbp^.tracecount:=tcount;
  if changereg<>nil then
    newbp^.changereg:=changereg^;



  breakpointcs.enter;
  try
    //add to the bp list
    BreakpointList.Add(newbp);
    //apply this breakpoint
    SetBreakpoint(newbp);
  finally
    breakpointcs.leave;
  end;



  Result := newbp;

  if frmBreakpointlist<>nil then
    postmessage(frmBreakpointlist.handle, WM_BPUPDATE,0,0); //tell the breakpointlist that there's been an update
end;

procedure TDebuggerThread.GetBreakpointList(address: uint_ptr; size: integer; var bplist: TBreakpointSplitArray);
{
splits up the given address and size into a list of debug register safe breakpoints (alligned)
}
var
  i: integer;
begin
  while size > 0 do
  begin
    if (processhandler.is64bit) and (size >= 8) then
    begin
      if (address mod 8) = 0 then
      begin
        setlength(bplist, length(bplist) + 1);
        bplist[length(bplist) - 1].address := address;
        bplist[length(bplist) - 1].size := 8;
        Inc(address, 8);
        Dec(size, 8);
      end
      else
      if (address mod 4) = 0 then
      begin
        setlength(bplist, length(bplist) + 1);
        bplist[length(bplist) - 1].address := address;
        bplist[length(bplist) - 1].size := 4;
        Inc(address, 4);
        Dec(size, 4);
      end
      else
      if (address mod 2) = 0 then
      begin
        setlength(bplist, length(bplist) + 1);
        bplist[length(bplist) - 1].address := address;
        bplist[length(bplist) - 1].size := 2;
        Inc(address, 2);
        Dec(size, 2);
      end
      else
      begin
        setlength(bplist, length(bplist) + 1);
        bplist[length(bplist) - 1].address := address;
        bplist[length(bplist) - 1].size := 1;
        Inc(address);
        Dec(size);
      end;

    end
    else
    if size >= 4 then //smaller than 8 bytes or not a 64-bit process
    begin
      if (address mod 4) = 0 then
      begin
        setlength(bplist, length(bplist) + 1);
        bplist[length(bplist) - 1].address := address;
        bplist[length(bplist) - 1].size := 4;
        Inc(address, 4);
        Dec(size, 4);
      end
      else    //not aligned on a 4 byte boundary
      if (address mod 2) = 0 then
      begin
        setlength(bplist, length(bplist) + 1);
        bplist[length(bplist) - 1].address := address;
        bplist[length(bplist) - 1].size := 2;
        Inc(address, 2);
        Dec(size, 2);
      end
      else
      begin
        //also not aligned on a 2 byte boundary, so use a 1 byte bp
        setlength(bplist, length(bplist) + 1);
        bplist[length(bplist) - 1].address := address;
        bplist[length(bplist) - 1].size := 1;
        Inc(address);
        Dec(size);
      end;
    end
    else
    if size >= 2 then
    begin
      if (address mod 2) = 0 then
      begin
        setlength(bplist, length(bplist) + 1);
        bplist[length(bplist) - 1].address := address;
        bplist[length(bplist) - 1].size := 2;
        Inc(address, 2);
        Dec(size, 2);
      end
      else
      begin
        //not aligned on a 2 byte boundary, so use a 1 byte bp
        setlength(bplist, length(bplist) + 1);
        bplist[length(bplist) - 1].address := address;
        bplist[length(bplist) - 1].size := 1;
        Inc(address);
        Dec(size);
      end;
    end
    else
    if size >= 1 then
    begin
      setlength(bplist, length(bplist) + 1);
      bplist[length(bplist) - 1].address := address;
      bplist[length(bplist) - 1].size := 1;
      Inc(address);
      Dec(size);
    end;
  end;
end;

function TDebuggerThread.GetUsableDebugRegister: integer;
{
will scan the current breakpoint list and see which debug register is unused.
if all are used up, return -1
}
var
  i: integer;
  available: array [0..3] of boolean;
begin

  breakpointcs.enter;
  try
    Result := -1;

    for i := 0 to 3 do
      available[i] := True;

    for i := 0 to breakpointlist.Count - 1 do
    begin
      if (pbreakpoint(breakpointlist.Items[i])^.breakpointMethod = bpmDebugRegister) and
        (pbreakpoint(breakpointlist.Items[i])^.active) then
        available[pbreakpoint(breakpointlist.Items[i])^.debugRegister] := False;
    end;

    for i := 0 to 3 do
      if available[i] then
      begin
        Result := i;
        break;
      end;

  finally
    breakpointcs.leave;
  end;

end;

procedure TDebuggerthread.FindWhatWrites(address: uint_ptr; size: integer);
begin
  FindCodeByBP(address, size, bptWrite);
end;

procedure TDebuggerthread.FindWhatAccesses(address: uint_ptr; size: integer);
begin
  FindCodeByBP(address, size, bptAccess);
end;

procedure TDebuggerthread.FindCodeByBP(address: uint_ptr; size: integer; bpt: TBreakpointTrigger);
var
  usedDebugRegister: integer;
  bplist: array of TBreakpointSplit;
  newbp: PBreakpoint;
  i: integer;

  foundcodedialog: TFoundcodeDialog;
begin
  //split up address and size into memory alligned sections
  setlength(bplist, 0);
  GetBreakpointList(address, size, bplist);

  usedDebugRegister := GetUsableDebugRegister;
  if usedDebugRegister = -1 then
    raise Exception.Create(
      rsAll4DebugRegistersAreCurrentlyUsedUpFreeOneAndTryA);

  //still here
  //create a foundcodedialog and add the breakpoint
  foundcodedialog := Tfoundcodedialog.Create(application);
  case bpt of
    bptAccess : foundcodedialog.Caption:=Format(rsTheFollowingOpcodesAccessed, [
      inttohex(address, 8)]);
    bptWrite : foundcodedialog.Caption:=Format(rsTheFollowingOpcodesWriteTo, [
      inttohex(address, 8)]);
  end;
  foundcodedialog.Show;

  newbp := AddBreakpoint(nil, bplist[0].address, bpt, bpmDebugRegister,
    bo_FindCode, usedDebugRegister, bplist[0].size, foundcodedialog, 0);

  if length(bplist) > 1 then
  begin
    for i := 1 to length(bplist) - 1 do
    begin
      usedDebugRegister := GetUsableDebugRegister;
      if usedDebugRegister = -1 then
        exit; //at least one has been set, so be happy...

      AddBreakpoint(newbp, bplist[i].address, bpt,
        bpmDebugRegister, bo_FindCode, usedDebugRegister,
        bplist[i].size, foundcodedialog, 0);
    end;
  end;

end;

function TDebuggerThread.stopBreakAndTrace(frmTracer: TFrmTracer): boolean;
var
  i: integer;
  bp: PBreakpoint;
begin
  Result := False;
  breakpointCS.enter;
  try
    for i := 0 to BreakpointList.Count - 1 do
      if PBreakpoint(breakpointlist[i]).frmTracer = frmTracer then
      begin
        bp := PBreakpoint(breakpointlist[i]);
        Result := True;
        break;
      end;

    if Result then
      RemoveBreakpoint(bp); //unsets and removes all breakpoints that belong to this


  finally
    breakpointCS.leave;
  end;

  //it doesn't really matter if it returns false, that would just mean the breakpoint got and it's tracing or has finished tracing
end;


function TDebuggerThread.CodeFinderStop(codefinder: TFoundCodeDialog): boolean;
var
  i: integer;
  bp: PBreakpoint;
begin
  Result := False;
  breakpointCS.enter;
  try
    for i := 0 to BreakpointList.Count - 1 do
      if PBreakpoint(breakpointlist[i]).FoundcodeDialog = codefinder then
      begin
        bp := PBreakpoint(breakpointlist[i]);
        Result := True;
        break;
      end;

    if Result then
      RemoveBreakpoint(bp); //unsets and removes all breakpoints that belong to this
  finally
    breakpointCS.leave;
  end;


end;


function TDebuggerthread.FindWhatCodeAccessesStop(frmchangedaddresses: Tfrmchangedaddresses): boolean;
var
  i: integer;
  bp: PBreakpoint;
begin
  Result := False;
  breakpointCS.enter;
  try
    for i := 0 to BreakpointList.Count - 1 do
      if PBreakpoint(breakpointlist[i]).frmchangedaddresses = frmchangedaddresses then
      begin
        bp := PBreakpoint(breakpointlist[i]);
        Result := True;
        break;
      end;

    if Result then
      RemoveBreakpoint(bp); //unsets and removes all breakpoints that belong to this
  finally
    breakpointCS.leave;
  end;
end;

function TDebuggerthread.setChangeRegBreakpoint(regmod: PRegisterModificationBP): PBreakpoint;
var
  method: TBreakpointMethod;
  useddebugregister: integer;
  address: ptruint;
  bp: pbreakpoint;
begin
  result:=nil;

  address:=regmod^.address;
  bp:=isBreakpoint(address);

  if bp<>nil then
    RemoveBreakpoint(bp);


  method:=bpmDebugRegister;
  usedDebugRegister := GetUsableDebugRegister;
  if usedDebugRegister = -1 then
  begin
    if MessageDlg(
      rsAllDebugRegistersAreUsedUpDoYouWantToUseASoftwareBP, mtConfirmation, [
        mbNo, mbYes], 0) = mrYes then
      method := bpmInt3
    else
      exit;

  end;

  //todo: Make this breakpoint show up in the memory view
  result:=AddBreakpoint(nil, regmod.address, bptExecute, method, bo_ChangeRegister, usedDebugRegister, 1, nil, 0, nil,nil,0, regmod);


end;

procedure TDebuggerthread.setBreakAndTraceBreakpoint(frmTracer: TFrmTracer; address: ptrUint; BreakpointTrigger: TBreakpointTrigger; bpsize: integer; count: integer; condition:string='');
var
  method: TBreakpointMethod;
  useddebugregister: integer;
  bp,bpsecondary: PBreakpoint;
  bplist: TBreakpointSplitArray;
  i: integer;
begin
  breakpointCS.enter;
  try
    setlength(bplist,0);
    GetBreakpointList(address, bpsize, bplist);


    method:=bpmDebugRegister;
    usedDebugRegister := GetUsableDebugRegister;
    if usedDebugRegister = -1 then
    begin
      if (BreakpointTrigger=bptExecute) then
      begin
        if MessageDlg(
          rsAllDebugRegistersAreUsedUpDoYouWantToUseASoftwareBP,
            mtConfirmation, [mbNo, mbYes], 0) = mrYes then
          method := bpmInt3
        else
          exit;
      end
      else
        messagedlg(rsAllDebugRegistersAreUsedUp, mtError, [mbok], 0);

    end;

    bp:=AddBreakpoint(nil, bplist[0].address, BreakpointTrigger, method, bo_BreakAndTrace, usedDebugRegister, bplist[0].size, nil, 0, nil,frmTracer,count);

    if bp<>nil then
      bp.traceendcondition:=strnew(pchar(condition));


    for i:=1 to length(bplist)-1 do
    begin
      useddebugregister:=GetUsableDebugRegister;
      if useddebugregister=-1 then exit;

      bpsecondary:=AddBreakpoint(bp, bplist[i].address, BreakpointTrigger, method, bo_BreakAndTrace, usedDebugregister, bplist[i].size, nil, 0, nil,frmTracer,count);
      bpsecondary.traceendcondition:=strnew(pchar(condition));
    end;


  finally
    breakpointCS.leave;
  end;
end;

procedure TDebuggerthread.FindWhatCodeAccesses(address: uint_ptr);
var method: TBreakpointMethod;
var frmChangedAddresses: tfrmChangedAddresses;
useddebugregister: integer;
begin
  method:=bpmDebugRegister;
  usedDebugRegister := GetUsableDebugRegister;
  if usedDebugRegister = -1 then
  begin
    if MessageDlg(
      rsAllDebugRegistersAreUsedUpDoYouWantToUseASoftwareBP, mtConfirmation, [
        mbNo, mbYes], 0) = mrYes then
      method := bpmInt3
    else
      exit;

  end;

  frmchangedaddresses:=tfrmChangedAddresses.Create(application) ;
  frmchangedaddresses.show;

  AddBreakpoint(nil, address, bptExecute, method, bo_FindWhatCodeAccesses, usedDebugRegister, 1, nil, 0, frmchangedaddresses);
end;

procedure TDebuggerthread.setbreakpointcondition(bp: PBreakpoint; easymode: boolean; script: string);
begin
  breakpointCS.enter;

  if bp.conditonalbreakpoint.script<>nil then
    StrDispose(bp.conditonalbreakpoint.script);

  bp.conditonalbreakpoint.script:=strnew(pchar(script));
  bp.conditonalbreakpoint.easymode:=easymode;
  breakpointCS.leave;
end;

function TDebuggerthread.getbreakpointcondition(bp: PBreakpoint; var easymode: boolean):pchar;
begin
  breakpointCS.enter;
  result:=bp.conditonalbreakpoint.script;
  easymode:=bp.conditonalbreakpoint.easymode;
  breakpointCS.leave;
end;

procedure TDebuggerthread.updatebplist(lv: TListview; showshadow: boolean);
{
Only called by the breakpointlist form running in the main thread. It's called after the WM_BPUPDATE is sent to the breakpointlist window
}
var
  i: integer;
  li: TListitem;
  bp: PBreakpoint;
  s: string;

  showcount: integer;
begin


  breakpointCS.enter;


  showcount:=0;
  for i := 0 to BreakpointList.Count - 1 do
  begin
    bp:=PBreakpoint(BreakpointList[i]);

    if bp.active or showshadow then
    begin
      inc(showcount);

      if i<lv.Items.Count then
        li:=lv.items[i]
      else
        li:=lv.items.add;

      li.data:=bp;
      li.Caption:=inttohex(bp.address,8);
      li.SubItems.Clear;

      li.SubItems.add(inttostr(bp.size));
      li.SubItems.Add(breakpointTriggerToString(bp.breakpointTrigger));
      s:=breakpointMethodToString(bp.breakpointMethod);
      if bp.breakpointMethod=bpmDebugRegister then
        s:=s+' ('+inttostr(bp.debugRegister)+')';

      li.SubItems.Add(s);


      li.SubItems.Add(breakpointActionToString(bp.breakpointAction));
      li.SubItems.Add(BoolToStr(bp.active, rsYes, rsNo));
      if bp.markedfordeletion then
        li.SubItems.Add(rsYes);
    end;
  end;

  for i:=lv.items.count-1 downto showcount do
    lv.items[i].Delete;

  breakpointCS.leave;
end;

procedure TDebuggerthread.SetEntryPointBreakpoint;
{Only called from the main thread, or synchronize}
var code,data: ptruint;
  bp: PBreakpoint;
  oldstate: boolean;
begin
  if fNeedsToSetEntryPointBreakpoint then
  begin
    fNeedsToSetEntryPointBreakpoint:=false;

    symhandler.reinitialize;
    symhandler.waitforsymbolsloaded;
    memorybrowser.GetEntryPointAndDataBase(code,data);

    //set the breakpoint preference to int3 for this breakpoint
    oldstate:=preferHwBP;
    preferHwBP:=false;

    try
      bp:=ToggleOnExecuteBreakpoint(code);

      if bp<>nil then
        bp.OneTimeOnly:=true;
    finally
      preferHwBP:=oldstate;
    end;

  end;
end;

function TDebuggerthread.SetOnExecuteBreakpoint(address: ptrUint; askforsoftwarebp: boolean = false; tid: dword=0): PBreakpoint;
var
  i: integer;
  found: boolean;
  originalbyte: byte;
  oldprotect, bw, br: dword;

  usableDebugReg: integer;
  method: TBreakpointMethod;
begin
  found := False;

  result:=nil;
  breakpointCS.enter;
  try
    //set the breakpoint
    method := bpmDebugRegister;

    if (not preferHwBP) and (dbcSoftwareBreakpoint in CurrentDebuggerInterface.DebuggerCapabilities) then //prefers int3
    begin
      if readProcessMemory(processhandle, pointer(address), @originalbyte, 1, br) then
        method := bpmInt3
    end;

    if method = bpmDebugRegister then //failure, try debug registers anyhow...
    begin
      usableDebugReg := GetUsableDebugRegister;

      if usableDebugReg = -1 then
      begin
        if askforsoftwarebp then
        begin
          if not (dbcSoftwareBreakpoint in CurrentDebuggerInterface.DebuggerCapabilities) then
          begin
            MessageDlg(rsOutOfHWBreakpoints, mtError, [mbok], 0);
            exit;
          end
          else
          begin
            if MessageDlg(
              rsAllDebugRegistersAreUsedUpDoYouWantToUseASoftwareBP,
                mtConfirmation, [mbNo, mbYes], 0) = mrYes then
            begin
              if readProcessMemory(processhandle, pointer(address), @originalbyte, 1, br) then
                method := bpmInt3
              else
                raise Exception.Create(
                  rsUnreadableMemoryUnableToSetSoftwareBreakpoint);
            end
            else
              exit;
          end

        end
        else
        begin
          if not (dbcSoftwareBreakpoint in CurrentDebuggerInterface.DebuggerCapabilities) then exit;
          method := bpmInt3;
        end;
      end;
    end;

    result:=AddBreakpoint(nil, address, bptExecute, method, bo_Break, usableDebugreg, 1, nil, tid);
  finally
    breakpointCS.leave;
  end;
end;

function TDebuggerthread.SetOnWriteBreakpoint(address: ptrUint; size: integer; tid: dword=0): PBreakpoint;
var
  i: integer;
  found: boolean;
  originalbyte: byte;
  oldprotect, bw, br: dword;

  usableDebugReg: integer;
  bplist: TBreakpointSplitArray;
begin
  found := False;

  result:=nil;
  breakpointCS.enter;
  try
    //set the breakpoint

    usableDebugReg := GetUsableDebugRegister;
    if usableDebugReg = -1 then
      raise Exception.Create(rsAllDebugRegistersAreUsedUp);

    setlength(bplist,0);
    GetBreakpointList(address, size, bplist);

    result:=AddBreakpoint(nil, bplist[0].address, bptWrite, bpmDebugRegister, bo_Break, usableDebugreg, bplist[0].size, nil, tid);
    for i:=1 to length(bplist)-1 do
    begin
      usableDebugReg:=GetUsableDebugRegister;
      if usableDebugReg=-1 then exit;
      AddBreakpoint(result, bplist[i].address, bptWrite, bpmDebugRegister, bo_Break, usableDebugreg, bplist[i].size, nil, tid);
    end;

  finally
    breakpointCS.leave;
  end;

end;


function TDebuggerthread.SetOnAccessBreakpoint(address: ptrUint; size: integer; tid: dword=0): PBreakpoint;
var
  i: integer;
  found: boolean;
  originalbyte: byte;
  oldprotect, bw, br: dword;

  usableDebugReg: integer;
  bplist: TBreakpointSplitArray;
begin
  found := False;

  result:=nil;
  breakpointCS.enter;
  try
    //set the breakpoint

    usableDebugReg := GetUsableDebugRegister;
    if usableDebugReg = -1 then
      raise Exception.Create(rsAllDebugRegistersAreUsedUp);

    setlength(bplist,0);
    GetBreakpointList(address, size, bplist);

    result:=AddBreakpoint(nil, bplist[0].address, bptAccess, bpmDebugRegister, bo_Break, usableDebugreg, bplist[0].size, nil, tid);
    for i:=1 to length(bplist)-1 do
    begin
      usableDebugReg:=GetUsableDebugRegister;
      if usableDebugReg=-1 then exit;
      AddBreakpoint(result, bplist[i].address, bptAccess, bpmDebugRegister, bo_Break, usableDebugreg, bplist[i].size, nil, tid);
    end;

  finally
    breakpointCS.leave;
  end;

end;

function TDebuggerthread.ToggleOnExecuteBreakpoint(address: ptrUint; tid: dword=0): PBreakpoint;
{Only called from the main thread}
var
  i: integer;
  found: boolean;
  originalbyte: byte;
  oldprotect, bw, br: dword;

  usableDebugReg: integer;
  method: TBreakpointMethod;
begin
  //find the breakpoint if it is already assigned and then remove it, else add the breakpoint
  found := False;

  result:=nil;
  breakpointCS.enter;
  try
    for i := 0 to BreakpointList.Count - 1 do
      if (PBreakpoint(BreakpointList[i])^.address = address) and
        (PBreakpoint(BreakpointList[i])^.breakpointTrigger = bptExecute) and
        ((PBreakpoint(BreakpointList[i])^.breakpointAction = bo_break) or (PBreakpoint(BreakpointList[i])^.breakpointAction = bo_ChangeRegister) ) and
        (PBreakpoint(BreakpointList[i])^.active) then
      begin
        found := True;
        RemoveBreakpoint(PBreakpoint(BreakpointList[i]));
        //remove breakpoint doesn't delete it, but only disables it and marks it for deletion, the debugger thread deletes it when it has nothing to do
      end;

    if not found then
    begin
      method := bpmDebugRegister;

      if (not preferHwBP) and (dbcSoftwareBreakpoint in CurrentDebuggerInterface.DebuggerCapabilities) then //prefers int3
      begin
        if readProcessMemory(processhandle, pointer(address), @originalbyte, 1, br) then
          method := bpmInt3
      end;

      if method = bpmDebugRegister then //failure, try debug registers anyhow...
      begin
        usableDebugReg := GetUsableDebugRegister;

        if usableDebugReg = -1 then
        begin

          if not (dbcSoftwareBreakpoint in CurrentDebuggerInterface.DebuggerCapabilities) then
          begin
            MessageDlg(rsOutOfHWBreakpoints, mtError, [mbok],0);
            exit;
          end
          else
          begin
            if MessageDlg(rsAllDebugRegistersAreUsedUpDoYouWantToUseASoftwareBP, mtConfirmation, [mbNo, mbYes], 0) = mrYes then
            begin
              if readProcessMemory(processhandle, pointer(address), @originalbyte, 1, br) then
                method := bpmInt3
              else
                raise Exception.Create(rsUnreadableMemoryUnableToSetSoftwareBreakpoint);
            end
            else
              exit;
          end

        end;
      end;

      result:=AddBreakpoint(nil, address, bptExecute, method, bo_Break, usableDebugreg, 1, nil, tid);
    end;

  finally
    breakpointCS.leave;
  end;
end;

function TDebuggerthread.getrealbyte(address: ptrUint): byte;
{
Called when the byte is a $cc
}
var bp: PBreakpoint;
begin
  result:=$cc;

  bp:=isBreakpoint(address);
  if bp<>nil then
  begin
    if bp.breakpointMethod=bpmInt3 then
      result:=bp.originalbyte;
  end;
end;

function TDebuggerthread.isBreakpoint(address: uint_ptr; address2: uint_ptr=0; includeinactive: boolean=false): PBreakpoint;
  {Checks if the given address has a breakpoint, and if so, return the breakpoint. Else return nil}
var
  i,j,k: integer;
begin
  Result := nil;

  if address2=0 then
    j:=0
  else
    j:=address2-address;

  breakpointCS.enter;
  try
    for i := 0 to BreakpointList.Count - 1 do
    begin
      for k:=0 to j do
      begin
        if (InRangeX(address+k, PBreakpoint(BreakpointList[i])^.address, PBreakpoint(BreakpointList[i])^.address + PBreakpoint(BreakpointList[i])^.size-1)) and
           (includeinactive or (PBreakpoint(BreakpointList[i])^.active)) then
        begin
          Result := PBreakpoint(BreakpointList[i]);
          exit;
        end;

      end;
    end;
  finally
    breakpointCS.leave;
  end;
end;

procedure TDebuggerthread.ContinueDebugging(continueOption: TContinueOption; runtillAddress: ptrUint=0);
{
Sets the way the debugger should continue, and triggers the sleeping thread to wait up and handle this changed event
}
var bp: PBreakpoint;
 ct: TDebugThreadHandler;
begin
  ct:=fcurrentThread;
  if ct<>nil then
  begin



    if ct.isWaitingToContinue then
    begin
      fcurrentThread:=nil;

      case continueOption of
        co_run, co_stepinto: ct.continueDebugging(continueOption);
        co_runtill:
        begin
          //set a 1 time breakpoint for this thread at the runtilladdress
          breakpointcs.enter;
          try
            bp:=isBreakpoint(runtilladdress);
            if bp<>nil then
            begin
              if bp.breakpointTrigger=bptExecute then
              begin
                if (bp.ThreadID<>0) and (bp.ThreadID<>ct.ThreadId) then //it's a thread specific breakpoint, but not for this thread
                  bp.ThreadId:=0; //break on all, the user will have to change this himself
              end
              else
                bp:=nil; //a useless breakpoint
            end;

            if bp=nil then
            begin
              bp:=SetOnExecuteBreakpoint(runTillAddress, false, ct.threadid);
//              bp:=ToggleOnExecuteBreakpoint(runTillAddress,fcurrentThread.threadid);
              if bp=nil then
                exit; //error,failure setting the breakpoint so exit. don't continue

              bp.OneTimeOnly:=true;
              bp.StepOverBp:=true;
            end;

          finally
            breakpointcs.leave;

          end;
          ct.continueDebugging(co_run);
        end;

        else ct.continueDebugging(continueOption);
      end;


    end;
  end;
end;

procedure TDebuggerthread.WaitTillAttachedOrError;
//wait till the OnAttachEvent has been set
//Because this routine runs in the main app thread do a CheckSynchronize (The debugger calls synchronize)
var
  i: integer;
  Result: TWaitResult;
  starttime: dword;
  currentloopstarttime: dword;
  timeout: dword;
begin
  starttime:=GetTickCount;

  if IsDebuggerPresent then //when debugging the debugger 10 seconds is too short
    timeout:=5000000
  else
    timeout:=10000;

  while (gettickcount-starttime)<timeout do
  begin
    currentloopstarttime:=GetTickCount;
    while CheckSynchronize and (GetTickCount-currentloopstarttime<50) do ; //synchronize for 50 milliseconds long

    Result := OnAttachEvent.WaitFor(50); //wait for 50 milliseconds for the OnAttachEvent
    if result=wrSignaled then break;
  end;

  {//wait just a little and wait for some threads
  sleep(100);
  i:=0;
  while (ThreadList.Count=0) and (i<10) do
  begin
    CheckSynchronize;
    sleep(100);

    inc(i);
  end; }


  if terminated then
  begin

    if CurrentDebuggerInterface.errorstring='' then
      raise exception.create(rsDebuggerFailedToAttach)
    else
      raise exception.create(CurrentDebuggerInterface.errorstring);


  end;
end;

procedure TDebuggerThread.lockSettings;
begin
  //prevent the user from changing this setting till next restart
  formsettings.cbUseWindowsDebugger.enabled:=false;
  formsettings.cbUseVEHDebugger.enabled:=false;
  formsettings.cbKDebug.enabled:=false;
end;

procedure TDebuggerthread.defaultConstructorcode;
begin
  breakpointCS := TGuiSafeCriticalSection.Create;
  threadlistCS := TGuiSafeCriticalSection.Create;
  OnAttachEvent := TEvent.Create(nil, True, False, '');
  OnContinueEvent := Tevent.Create(nil, true, False, '');
  threadlist := TList.Create;
  BreakpointList := TList.Create;
  eventhandler := TDebugEventHandler.Create(self, OnAttachEvent, OnContinueEvent, breakpointlist, threadlist, breakpointCS, threadlistCS);


  //get config parameters
  handlebreakpoints := formsettings.cbHandleBreakpoints.Checked;
  hidedebugger := formsettings.checkbox1.Checked;
  canusedebugregs := formsettings.rbDebugAsBreakpoint.Checked;

  //setup the used debugger
  if formsettings.cbUseWindowsDebugger.checked then
    CurrentDebuggerInterface:=TWindowsDebuggerInterface.create
  else if formsettings.cbUseVEHDebugger.checked then
    CurrentDebuggerInterface:=TVEHDebugInterface.create
  else if formsettings.cbKDebug.checked then
  begin
    globalDebug:=formsettings.cbGlobalDebug.checked;
    CurrentDebuggerInterface:=TKernelDebugInterface.create(globalDebug, formsettings.cbCanStepKernelcode.checked);
  end;




  //clean up some debug views

  if formdebugstrings = nil then
    formdebugstrings := Tformdebugstrings.Create(application);

  formdebugstrings.listbox1.Clear;
end;


constructor TDebuggerthread.MyCreate2(filename: string; parameters: string; breakonentry: boolean=true); overload;
begin
  inherited Create(true);
  defaultconstructorcode;


  if not (dbcBreakOnEntry in CurrentDebuggerInterface.DebuggerCapabilities) then
  begin
    MessageDlg(Format(rsThisDebuggerInterfaceDoesnTSupportBreakOnEntryYet, [CurrentDebuggerInterface.name]), mtError, [mbok], 0);
    terminate;
    start;
    exit;
  end;

  fRunning:=true;
  lockSettings;

  createProcess:=true;
  self.filename:=filename;
  self.parameters:=parameters;
  self.fNeedsToSetEntryPointBreakpoint:=breakonentry;

  start;
  WaitTillAttachedOrError;
end;

constructor TDebuggerthread.MyCreate2(processID: THandle);
begin

  defaultconstructorcode;

  createProcess:=false;
  fRunning:=true;
  locksettings;

  inherited Create(true);

  Start;


  WaitTillAttachedOrError;
end;

destructor TDebuggerthread.Destroy;
var i: integer;
begin
  terminate;
  waitfor;


  if OnAttachEvent <> nil then
  begin
    OnAttachEvent.SetEvent;
    FreeAndNil(OnAttachEvent);
  end;

  if threadlist <> nil then
  begin
    for i := 0 to threadlist.Count - 1 do
      TDebugThreadHandler(threadlist.Items[i]).Free;
    FreeAndNil(threadlist);
  end;

  if breakpointlist <> nil then
  begin
    for i := 0 to breakpointlist.Count - 1 do
      freemem(breakpointlist.Items[i]);

    FreeAndNil(breakpointlist);
  end;

  if breakpointCS <> nil then
    FreeAndNil(breakpointCS);

  if threadlistCS<>nil then
    freeAndNil(threadlistCS);

  if eventhandler <> nil then
    FreeAndNil(eventhandler);

  inherited Destroy;
end;

end.

