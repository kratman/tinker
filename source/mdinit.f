c
c
c     ###################################################
c     ##  COPYRIGHT (C)  1990  by  Jay William Ponder  ##
c     ##              All Rights Reserved              ##
c     ###################################################
c
c     ###############################################################
c     ##                                                           ##
c     ##  subroutine mdinit  --  initialize a dynamics trajectory  ##
c     ##                                                           ##
c     ###############################################################
c
c
c     "mdinit" initializes the velocities and accelerations
c     for a molecular dynamics trajectory, including restarts
c
c
      subroutine mdinit
      use sizes
      use atomid
      use atoms
      use bath
      use files
      use inform
      use iounit
      use keys
      use mdstuf
      use molcul
      use moldyn
      use mpole
      use units
      use uprior
      implicit none
      integer i,j,k,idyn
      integer size,next
      integer lext,freeunit
      real*8 e,ekt,qterm
      real*8 maxwell,speed
      real*8 vec(3)
      real*8, allocatable :: derivs(:,:)
      logical exist
      character*7 ext
      character*20 keyword
      character*120 dynfile
      character*120 record
      character*120 string
c
c
c     set default parameters for the dynamics trajectory
c
      integrate = 'VERLET'
      bmnmix = 8
      nfree = 0
      irest = 1
      velsave = .false.
      frcsave = .false.
      uindsave = .false.
      use_pred = .false.
      polpred = 'LSQR'
      iprint = 100
c
c     set default values for temperature and pressure control
c
      thermostat = 'NOSE-HOOVER'
      tautemp = 0.2d0
      collide = 0.1d0
      do i = 1, maxnose
         vnh(i) = 0.0d0
         qnh(i) = 0.0d0
         gnh(i) = 0.0d0
      end do
      barostat = 'BERENDSEN'
      anisotrop = .false.
      taupres = 2.0d0
      compress = 0.000046d0
      vbar = 0.0d0
      qbar = 0.0d0
      gbar = 0.0d0
      eta = 0.0d0
      voltrial = 20
      volmove = 100.0d0
      volscale = 'ATOMIC'
c
c     check for keywords containing any altered parameters
c
      do i = 1, nkey
         next = 1
         record = keyline(i)
         call gettext (record,keyword,next)
         call upcase (keyword)
         string = record(next:120)
         if (keyword(1:16) .eq. 'DEGREES-FREEDOM ') then
            read (string,*,err=10,end=10)  nfree
         else if (keyword(1:15) .eq. 'REMOVE-INERTIA ') then
            read (string,*,err=10,end=10)  irest
         else if (keyword(1:14) .eq. 'SAVE-VELOCITY ') then
            velsave = .true.
         else if (keyword(1:11) .eq. 'SAVE-FORCE ') then
            frcsave = .true.
         else if (keyword(1:13) .eq. 'SAVE-INDUCED ') then
            uindsave = .true.
         else if (keyword(1:14) .eq. 'POLAR-PREDICT ') then
            use_pred = .true.
            call getword (record,polpred,next)
            call upcase (polpred)
         else if (keyword(1:16) .eq. 'TAU-TEMPERATURE ') then
            read (string,*,err=10,end=10)  tautemp
         else if (keyword(1:10) .eq. 'COLLISION ') then
            read (string,*,err=10,end=10)  collide
         else if (keyword(1:13) .eq. 'TAU-PRESSURE ') then
            read (string,*,err=10,end=10)  taupres
         else if (keyword(1:9) .eq. 'COMPRESS ') then
            read (string,*,err=10,end=10)  compress
         else if (keyword(1:13) .eq. 'VOLUME-TRIAL ') then
            read (string,*,err=10,end=10)  voltrial
         else if (keyword(1:12) .eq. 'VOLUME-MOVE ') then
            read (string,*,err=10,end=10)  volmove
         else if (keyword(1:13) .eq. 'VOLUME-SCALE ') then
            call getword (record,volscale,next)
            call upcase (volscale)
         else if (keyword(1:9) .eq. 'PRINTOUT ') then
            read (string,*,err=10,end=10)  iprint
         end if
   10    continue
      end do
c
c     make sure all atoms or groups have a nonzero mass
c
      do i = 1, n
         if (mass(i).le.0.0d0 .and. atomic(i).ne.0) then
            mass(i) = 1.0d0
            totmass = totmass + 1.0d0
            write (iout,30)  i
   30       format (/,' MDINIT  --  Warning, Mass of Atom',i6,
     &                    ' Set to 1.0 for Dynamics')
         end if
      end do
c
c     perform dynamic allocation of some global arrays
c
      if (.not. allocated(udalt))  allocate (udalt(maxualt,3,n))
      if (.not. allocated(upalt))  allocate (upalt(maxualt,3,n))
c
c     set the Gear predictor binomial coefficients
c
      gear(1) = 6.0d0
      gear(2) = -15.0d0
      gear(3) = 20.0d0
      gear(4) = -15.0d0
      gear(5) = 6.0d0
      gear(6) = -1.0d0
      gear(7) = 0.0d0
c
c     set always stable predictor-corrector (ASPC) coefficients
c
      aspc(1) = 22.0d0 / 7.0d0
      aspc(2) = -55.0d0 / 14.0d0
      aspc(3) = 55.0d0 / 21.0d0
      aspc(4) = -22.0d0 / 21.0d0
      aspc(5) = 5.0d0 / 21.0d0
      aspc(6) = -1.0d0 / 42.0d0
      aspc(7) = 0.0d0
c
c    initialize prior values of induced dipole moments
c
      nualt = 0
      do i = 1, npole
         do j = 1, 3
            do k = 1, maxualt
               udalt(k,j,i) = 0.0d0
               upalt(k,j,i) = 0.0d0
            end do
         end do
      end do
c
c     set the number of degrees of freedom for the system
c
      if (nfree .eq. 0) then
         nfree = 3 * n
         nfree = nfree - 3
      end if
c
c     check for a nonzero number of degrees of freedom
c
      if (nfree .lt. 0)  nfree = 0
      if (nfree .eq. 0) then
         write (iout,60)
   60    format (/,' MDINIT  --  No Degrees of Freedom for Dynamics')
         call fatal
      end if
c
c     set masses for Nose-Hoover thermostat and barostat
c
      ekt = gasconst * kelvin
      qterm = ekt * tautemp * tautemp
      do j = 1, maxnose
         if (qnh(j) .eq. 0.0d0)  qnh(j) = qterm
      end do
      qnh(1) = dble(nfree) * qnh(1)
c
c     decide whether to remove center of mass motion
c
      dorest = .true.
      if (irest .eq. 0)  dorest = .false.
c
c     perform dynamic allocation of some global arrays
c
      if (.not. allocated(v))  allocate (v(3,n))
      if (.not. allocated(a))  allocate (a(3,n))
      if (.not. allocated(aalt))  allocate (aalt(3,n))
c
c     try to restart using prior velocities and accelerations
c
      dynfile = filename(1:leng)//'.dyn'
      call version (dynfile,'old')
      inquire (file=dynfile,exist=exist)
      if (exist) then
         idyn = freeunit ()
         open (unit=idyn,file=dynfile,status='old')
         rewind (unit=idyn)
         call readdyn (idyn)
         close (unit=idyn)
c
c     set velocities and accelerations for Cartesian dynamics
c
      else
         allocate (derivs(3,n))
         call gradient (e,derivs)
         do i = 1, n
            if (mass(i).ne.0.0d0) then
               speed = maxwell (mass(i),kelvin)
               call ranvec (vec)
               do j = 1, 3
                  v(j,i) = speed * vec(j)
                  a(j,i) = -convert * derivs(j,i) / mass(i)
                  aalt(j,i) = a(j,i)
               end do
            else
               do j = 1, 3
                  v(j,i) = 0.0d0
                  a(j,i) = 0.0d0
                  aalt(j,i) = 0.0d0
               end do
            end if
         end do
         deallocate (derivs)
         call mdrest (0)
      end if
c
c     check for any prior dynamics coordinate sets
c
      i = 0
      exist = .true.
      do while (exist)
         i = i + 1
         lext = 3
         call numeral (i,ext,lext)
         dynfile = filename(1:leng)//'.'//ext(1:lext)
         inquire (file=dynfile,exist=exist)
         if (.not.exist .and. i.lt.100) then
            lext = 2
            call numeral (i,ext,lext)
            dynfile = filename(1:leng)//'.'//ext(1:lext)
            inquire (file=dynfile,exist=exist)
         end if
         if (.not.exist .and. i.lt.10) then
            lext = 1
            call numeral (i,ext,lext)
            dynfile = filename(1:leng)//'.'//ext(1:lext)
            inquire (file=dynfile,exist=exist)
         end if
      end do
      nprior = i - 1
      return
      end
