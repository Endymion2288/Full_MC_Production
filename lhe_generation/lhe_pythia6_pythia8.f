      program convert_pythia6_pythia8
C convert the lhe file from pythia6 convention to pythia8
C Usage: ./lhe_pythia6_pythia8 <input.lhe> <py8_onia_user.inp> [output.lhe]
C If output.lhe is not specified, it will be input_py8.lhe
      implicit none
      integer ifile,ofile,i,j
      character*1000 event_file
      character*1004 event_file2
      character*1000 onia_inp_file
      integer maxlen
      parameter (maxlen=5000)
      character*(maxlen) string
      logical found,lexists
      integer reason,inindex,inindex2,IEVNT,IBEG
      integer idup8
      logical finddiff
      integer NUPREAD,NUP,IDPRUP,IDUP,ISTUP,MOTHUP(2),ICOLUP(2)
      double precision PUP(5),VTIMUP,SPINUP,XWGTUP,SCALUP,AQEDUP,AQCDUP
      integer new_color(2)
      INTEGER MAXPUP
      PARAMETER (MAXPUP=100)
      integer qid
      integer n_onia,i_onia
      integer pdg_onia(10)
      logical quarkonium_pdg
      external quarkonium_pdg
      integer nargs
      character*1000 output_file
      logical has_output_arg

C... Parse command line arguments
      nargs = iargc()
      IF(nargs.LT.2)THEN
         WRITE(*,*)"Usage: lhe_pythia6_pythia8 <input.lhe>"//
     $        " <py8_onia_user.inp> [output.lhe]"
         WRITE(*,*)"  input.lhe - Input LHE file (Pythia6)"
         WRITE(*,*)"  py8_onia_user.inp - Onia PDG config"
         WRITE(*,*)"  output.lhe - Output (default: *_py8.lhe)"
         STOP
      ENDIF

      call getarg(1, event_file)
      call getarg(2, onia_inp_file)
      
      has_output_arg = .FALSE.
      IF(nargs.GE.3)THEN
         call getarg(3, output_file)
         has_output_arg = .TRUE.
      ENDIF

C... Validate input LHE file
      INQUIRE(FILE=TRIM(event_file),EXIST=lexists)
      IF(.NOT.lexists)THEN
         WRITE(*,*)"ERROR: Input LHE file not found: "
     $        //TRIM(event_file)
         STOP
      ENDIF

C... Validate onia config file
      INQUIRE(FILE=TRIM(onia_inp_file),EXIST=lexists)
      IF(.NOT.lexists)THEN
         WRITE(*,*)"ERROR: Onia config file not found: "
     $        //TRIM(onia_inp_file)
         STOP
      ENDIF

C... Determine output filename
      IF(has_output_arg)THEN
         event_file2=TRIM(output_file)
      ELSE
         inindex=INDEX(event_file,'.lhe')
         IF(inindex.GT.0)THEN
            event_file2=trim(event_file(1:inindex-1))//"_py8.lhe"
         ELSE
            event_file2=trim(event_file)//"_py8.lhe"
         ENDIF
      ENDIF

      WRITE(*,*)"Input LHE file:  "//TRIM(event_file)
      WRITE(*,*)"Onia config:     "//TRIM(onia_inp_file)
      WRITE(*,*)"Output LHE file: "//TRIM(event_file2)

C... get the physical quarkonium mesons
      open(2133,FILE=TRIM(onia_inp_file),action="read")
      read(2133,*)n_onia
      IF(n_onia.GT.10)THEN
          write(*,*)"warning: find too many onia in config"//
     $        " (set to 10)"
          n_onia=10
       ENDIF
      IF(n_onia.GT.0)THEN
         read(2133,*)(pdg_onia(i),i=1,n_onia)
      ENDIF
      CLOSE(UNIT=2133)
      WRITE(*,*)"Number of onia particles: ",n_onia
      IF(n_onia.GT.0)THEN
         WRITE(*,*)"Onia PDG codes: ",(pdg_onia(i),i=1,n_onia)
      ENDIF
      ifile=1434
      ofile=1435
      open(unit=ifile,file=trim(event_file),status='old')
      open(unit=ofile,file=trim(event_file2),status='new')
      IEVNT=0
C     Loop until finds line beginning with "<event>" or "<event "
      finddiff=.FALSE.
      DO WHILE(.TRUE.)
         READ(ifile,'(a)',END=150,ERR=220) STRING
         IBEG=0
 210     IBEG=IBEG+1
C...  Allow indentation.
         IF(STRING(IBEG:IBEG).EQ.' '.AND.IBEG.LT.MAXLEN-6) GOTO 210
         IF(STRING(IBEG:IBEG+6).NE.'<event>'.AND.
     $        STRING(IBEG:IBEG+6).NE.'<event ') GOTO 200
C...Read first line of event info.
         WRITE(ofile,'(a)',ERR=330)TRIM(STRING)
         READ(ifile,503,END=150,ERR=230) NUPREAD,IDPRUP,XWGTUP,SCALUP,
     $        AQEDUP,AQCDUP
         WRITE(ofile,503,ERR=330)NUPREAD,IDPRUP,XWGTUP,SCALUP
     $        ,AQEDUP,AQCDUP
         IEVNT=IEVNT+1
         IF(NUPREAD.GT.MAXPUP)THEN
            WRITE(*,*)"ERROR:Please enlarge MAXPUP"
            STOP
         ENDIF
         i_onia=0
         DO I=1,NUPREAD
            READ(ifile,504,END=150,ERR=230) IDUP,ISTUP,
     $           MOTHUP(1),MOTHUP(2),ICOLUP(1),ICOLUP(2),
     $           (PUP(J),J=1,5),VTIMUP,SPINUP
            IF(quarkonium_pdg(IDUP))THEN
               i_onia=i_onia+1
               IF(ABS(IDUP).LT.9900000)THEN
                  IDUP8=pdg_onia(i_onia)
               ELSE
                  call convert_pdg_PY6_PY8(pdg_onia(i_onia),IDUP,IDUP8)
               ENDIF
            ELSE
               IDUP8=IDUP
            ENDIF
            IF(.not.finddiff.AND.IDUP.NE.IDUP8)finddiff=.TRUE.
            WRITE(ofile,504,ERR=330) IDUP8,ISTUP,
     $              MOTHUP(1),MOTHUP(2),
     $              ICOLUP(1),ICOLUP(2),
     $              (PUP(J),J=1,5),VTIMUP,SPINUP
         ENDDO
         GOTO 201

 200     CONTINUE
         WRITE(ofile,'(a)',ERR=330)TRIM(STRING)
 201     CONTINUE
      END DO
 150  CONTINUE
      WRITE(*,*)"INFO:GET TOTAL NUMBER OF EVENTS = ",IEVNT
      CLOSE(UNIT=ifile)
      CLOSE(UNIT=ofile)
      IF(.not.finddiff)THEN
         call system("rm "//trim(event_file2))
         call system("ln -s "//trim(event_file)//" "//trim(event_file2))
      ENDIF
      RETURN
 220  WRITE(*,*) ' Failed to read LHEF non-event information,'
      WRITE(*,*) ' number of accepted events = ',IEVNT 
      STOP
 230  WRITE(*,*) ' Failed to read LHEF event information,'
      WRITE(*,*) ' number of accepted events = ',IEVNT
      STOP
 330    WRITE(*,*) ' Failed to write LHEF event information,'
        WRITE(*,*) ' number of accepted events = ',IEVNT
        STOP
 503  FORMAT(1P,2I6,4E14.6)
 504  FORMAT(1P,I8,5I5,5E18.10,E14.6,E12.4)
      END

      ! they are in htmldoc/ParticleData.html of Pythia8.1
      ! and in share/Pythia8/xmldoc/ParticleData.html of Pythia8.2 
      SUBROUTINE convert_pdg_PY6_PY8(pdg_state,ipdgt6,ipdgt8)
      IMPLICIT NONE
      INTEGER ipdgt6
      INTEGER ipdgt8
      INTEGER pdg_state ! the pdg of the physical state
      INTEGER nS,nQ,nR,nL,nJ
      IF(ABS(ipdgt6).LT.9900000)THEN
         ipdgt8=ipdgt6
         RETURN
      ENDIF
      nQ=MOD(ABS(ipdgt6)/100,10)
      IF(nQ.NE.MOD(ABS(pdg_state)/100,10))THEN
         WRITE(*,*)"ERROR: does not match :",ipdgt6,pdg_state
         STOP
      ENDIF
      nR=MOD(ABS(pdg_state)/100000,10)
      nL=MOD(ABS(pdg_state)/10000,10)
      nJ=MOD(ABS(pdg_state),10)

      ipdgt8=ABS(ipdgt6)-9900000
      nS=2 ! for CO, 0 is 3S1, 1 is 1S0, and 2 is 3PJ
      IF(ipdgt8.EQ.nQ*110+3)THEN
         nS=0
      ELSEIF(ipdgt8.EQ.nQ*110+1)THEN
         nS=1
      ENDIF
      ipdgt8=9900000+10000*nQ+1000*nS+100*nR+10*nL+nJ
      RETURN
      END SUBROUTINE Convert_pdg_PY6_PY8

      FUNCTION quarkonium_pdg(ipdg)
      IMPLICIT NONE
      INTEGER ipdg
      LOGICAL charmonium_pdg,bottomonium_pdg,Bc_pdg
      external charmonium_pdg,bottomonium_pdg,Bc_pdg
      LOGICAL quarkonium_pdg
      quarkonium_pdg=charmonium_pdg(ipdg).OR.
     $     bottomonium_pdg(ipdg).OR.Bc_pdg(ipdg)
      RETURN
      END FUNCTION quarkonium_pdg

      FUNCTION charmonium_pdg(ipdg)
      IMPLICIT NONE
      INTEGER ipdg
      LOGICAL charmonium_pdg
      charmonium_pdg=ipdg.EQ.443.OR.ipdg.EQ.441.OR.ipdg.EQ.10443
      charmonium_pdg=charmonium_pdg.OR.ipdg.EQ.10441.OR.ipdg.EQ.20443
      charmonium_pdg=charmonium_pdg.OR.ipdg.EQ.445
      charmonium_pdg=charmonium_pdg.OR.ipdg.EQ.9910441
      charmonium_pdg=charmonium_pdg.OR.ipdg.EQ.9900443
      charmonium_pdg=charmonium_pdg.OR.ipdg.EQ.9900441
      charmonium_pdg=charmonium_pdg.OR.
     $     (ipdg.GT.441000.AND.ipdg.LT.443200)
      RETURN
      END FUNCTION charmonium_pdg

      FUNCTION bottomonium_pdg(ipdg)
      IMPLICIT NONE
      INTEGER ipdg
      LOGICAL bottomonium_pdg
      bottomonium_pdg=ipdg.EQ.553.OR.ipdg.EQ.551.OR.ipdg.EQ.10553
      bottomonium_pdg=bottomonium_pdg.OR.ipdg.EQ.10551.OR.ipdg.EQ.20553
      bottomonium_pdg=bottomonium_pdg.OR.ipdg.EQ.555
      bottomonium_pdg=bottomonium_pdg.OR.ipdg.EQ.9910551
      bottomonium_pdg=bottomonium_pdg.OR.ipdg.EQ.9900553
      bottomonium_pdg=bottomonium_pdg.OR.ipdg.EQ.9900551
      bottomonium_pdg=bottomonium_pdg.OR.
     $     (ipdg.GT.551000.AND.ipdg.LT.553200)
      RETURN
      END FUNCTION bottomonium_pdg

      FUNCTION Bc_pdg(ipdg)
      IMPLICIT NONE
      INTEGER ipdg
      LOGICAL Bc_pdg
      Bc_pdg=ABS(ipdg).EQ.555.OR.ABS(ipdg).EQ.543.OR.ABS(ipdg).EQ.541
      Bc_pdg=Bc_pdg.OR.ABS(ipdg).EQ.545.OR.
     $     ABS(ipdg).EQ.10541.OR.ABS(ipdg).EQ.20543
      Bc_pdg=Bc_pdg.OR.(ABS(ipdg).GT.451000.AND.ABS(ipdg).LT.453200)
      RETURN
      END FUNCTION Bc_pdg
