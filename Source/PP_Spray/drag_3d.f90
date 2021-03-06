module drag_module

  implicit none

  public

contains

  subroutine update_particles(np, lev, particles, state, state_lo, state_hi, &
                              source, source_lo, source_hi, domlo, domhi, &
                              plo, phi, reflect_lo, reflect_hi, &
                              dx, dt, do_move) &
       bind(c,name='update_particles')

    use iso_c_binding
    ! use bl_error_module
    use eos_module
    use network
    use amrex_fort_module, only : amrex_real
    use meth_params_module, only : NVAR, URHO, UMX, UMY, UMZ, UEDEN, UEINT, UTEMP, UFS
    use particle_mod      , only: particle_t
    use fuel_properties
    use control_parameters
    use spray_module
    use transport_module, only : get_transport_coeffs
    implicit none

    integer,          intent(in   )        :: np
    type(particle_t), intent(inout)        :: particles(np)
    integer,          intent(in   )        :: state_lo(3), state_hi(3)
    integer,          intent(in   )        :: source_lo(3), source_hi(3)
    integer,          intent(in   )        :: domlo(3), domhi(3)
    real(amrex_real), intent(in   )        :: state &
         (state_lo(1):state_hi(1),state_lo(2):state_hi(2),state_lo(3):state_hi(3),NVAR)
    real(amrex_real), intent(inout)        :: source &
         (source_lo(1):source_hi(1),source_lo(2):source_hi(2),source_lo(3):source_hi(3),NVAR)
    real(amrex_real), intent(in   )        :: plo(3),phi(3),dx(3),dt
    integer,          intent(in   )        :: do_move, lev
    integer,          intent(in   )        :: reflect_lo(3), reflect_hi(3)

    integer          :: i,j,k,i2,j2,k2,n,nc,nf,iloc,jloc,kloc,ii,jj,kk,is_to_skip,ispec_loc
    real(amrex_real) :: wx_lo, wy_lo, wz_lo, wx_hi, wy_hi, wz_hi
    real(amrex_real) :: lx, ly, lz, lx2, ly2, lz2
    real(amrex_real) :: half_dt
    real(amrex_real) :: inv_dx(3), inv_vol
    real(amrex_real) :: force(3), fluid_vel(3), fluid_dens, fluid_temp, drag_coef
    real(amrex_real) :: rholoc(0:1,0:1,0:1),Tloc(0:1,0:1,0:1),Yloc(0:1,0:1,0:1,1:nspec) 
    real(amrex_real) :: fluid_pres, fluid_Y(nspec), Y_dot(nspec_f)
    real(amrex_real) :: m_dot, d_dot, convection, tmp_conv
    real(amrex_real) :: diff_u, diff_v, diff_w, diff_velmag, visc, reyn, drag, pmass
    real(amrex_real) :: heat_src, kinetic_src, prandtl, therm_cond
    real(amrex_real) :: cp_d_av, inv_Ru, inv_cp_d, delta_T
    real(amrex_real) :: coef_lll, coef_hll, coef_lhl, coef_hhl
    real(amrex_real) :: coef_llh, coef_hlh, coef_lhh, coef_hhh

    integer :: is, ie, L, M
    integer :: lo(3), hi(3)
    real(amrex_real), dimension(nspec_f) :: inv_diff_temp ! 1/(T_crit - T_boil)
    real(amrex_real), dimension(nspec_f) :: invfmolwt
    real(amrex_real), dimension(nspec_f) :: inv_boil_temp
    real(amrex_real), dimension(nspec_f) :: inv_density
    real(amrex_real), dimension(nspec_f) :: L_fuel
    real(amrex_real), dimension(nspec_f) :: h_skin
    real(amrex_real), dimension(np) :: fluid_molwt
    ! Species Diffusion Coefficient Array
    real(amrex_real), dimension(1,1,1,nspec) :: D_dummy
    real(amrex_real), dimension(1,1,1,nspec) :: Y_dummy
    real(amrex_real), dimension(1,1,1) :: T_dummy
    real(amrex_real), dimension(1,1,1) :: r_dummy
    real(amrex_real), dimension(1,1,1) :: xi_dummy
    real(amrex_real), dimension(1,1,1) :: la_dummy
    real(amrex_real), dimension(1,1,1) :: mu_dummy
    real(amrex_real), dimension(np,nspec_f) :: D_skin
    ! Species skin Schmidt number
    real(amrex_real), dimension(np,nspec_f) :: Sc_skin
    ! Sherwood number at skin temperature
    real(amrex_real), dimension(np,nspec_f) :: Sh
    ! Spalding number
    real(amrex_real), dimension(np,nspec_f) :: spalding_B
    ! Thermal Spalding number
    real(amrex_real), dimension(np,nspec_f) :: B_T

    real(amrex_real), dimension(np) :: inv_tau
    ! Shear Viscosity
    real(amrex_real), dimension(np) :: mu_skin
    ! Bulk  Viscosity (not used, but returned by transport routines)
    real(amrex_real), dimension(np) :: xi_skin
    ! Bulk  Viscosity (not used, but returned by transport routines)
    real(amrex_real), dimension(np) :: lambda_skin
    ! Heat capacity
    real(amrex_real), dimension(np) :: cp_skin
    real(amrex_real), dimension(np,nspec_f) :: cp_f
    real(amrex_real), dimension(np) :: temp_diff
    real(amrex_real), dimension(np) :: temp_skin
    real(amrex_real), dimension(np) :: Pr_skin
    real(amrex_real), dimension(np) :: Nu

    real*8, parameter :: pi = 3.1415926535897932d0
    real*8, parameter :: half_pi = 0.5d0*Pi
    real*8, parameter :: pi_six = Pi/6.0d0
    real*8, parameter :: one_third = 1.0d0/3.0d0

    ! Reference pressure of the boiling temperature (1 atm)
    real(amrex_real) :: p0 = 1.013e6 ! dyn/cm2
    ! Universal Gas Constant (Ru)
    real*8, parameter :: Ru = 8.31447e+7 ! dyn.cm

    type (eos_t) :: eos_state

    inv_dx = 1.0d0/dx
    inv_vol = inv_dx(1) * inv_dx(2) * inv_dx(3)
    half_dt = 0.5d0 * dt
    inv_Ru = 1.0d0/Ru ! Reciprocal of Gas Constant

    ! ****************************************************
    ! Fuel properties
    ! ****************************************************

    ! Reciprocal of molecular weight, boiling temperature, species density,
    ! etc
    do L = 1,nspec_f
      invfmolwt(L) = 1.0d0/fuel_molwt(L)
      inv_boil_temp(L) = 1.0d0/fuel_boil_temp(L)
      inv_density(L) = 1.0d0/fuel_density(L)
      inv_diff_temp(L) = (fuel_crit_temp(L)-fuel_boil_temp(L))
      inv_diff_temp(L) = 1.0d0/inv_diff_temp(L)
           if (inv_diff_temp(L).ne.inv_diff_temp(L)) then 
             print *,'PARTICLE ID ', particles(n)%temp,' inv BUST ',fuel_boil_temp(L),fuel_crit_temp(L)
             stop
           endif

    end do
    ! set initial CP - same for all droplets
    cp_d_av = sum(fuel_cp(1:nspec_f)*fuel_mass_frac(1:nspec_f))

    call build(eos_state)

    do n = 1, np

       if ((particles(n)%id.eq.-1).or. & 
           (particles(n)%pos(1).ne.particles(n)%pos(1))) then 


       else

       ! ****************************************************
       ! Compute the forcing term at the particle locations
       ! ****************************************************

       ! FIX: avoid freezing
       particles(n)%temp = max(particles(n)%temp,250d0)

       lx = (particles(n)%pos(1) - plo(1))*inv_dx(1) + 0.5d0
       ly = (particles(n)%pos(2) - plo(2))*inv_dx(2) + 0.5d0
       lz = (particles(n)%pos(3) - plo(3))*inv_dx(3) + 0.5d0

       i = floor(lx)
       j = floor(ly)
       k = floor(lz)

       if (i-1 .lt. state_lo(1) .or. i .gt. state_hi(1) .or. &
           j-1 .lt. state_lo(2) .or. j .gt. state_hi(2) .or. &
           k-1 .lt. state_lo(3) .or. k .gt. state_hi(3)) then
          print *,'PARTICLE ID ', particles(n)%id,' REACHING OUT OF BOUNDS AT (I,J,K) = ',i,j,k
          print *,'Array bounds are ', state_lo(:), state_hi(:)
          print *,'(x,y,z) are ', particles(n)%pos(1), particles(n)%pos(2), particles(n)%pos(3)
       !  call bl_error('Aborting in update_particles')
       end if

       wx_hi = lx - i
       wy_hi = ly - j
       wz_hi = lz - k

       wx_lo = 1.0d0 - wx_hi
       wy_lo = 1.0d0 - wy_hi
       wz_lo = 1.0d0 - wz_hi
  
       coef_lll = wx_lo * wy_lo * wz_lo
       coef_hll = wx_hi * wy_lo * wz_lo
       coef_lhl = wx_lo * wy_hi * wz_lo
       coef_hhl = wx_hi * wy_hi * wz_lo
       coef_llh = wx_lo * wy_lo * wz_hi
       coef_hlh = wx_hi * wy_lo * wz_hi
       coef_lhh = wx_lo * wy_hi * wz_hi
       coef_hhh = wx_hi * wy_hi * wz_hi

       ! Compute the velocity of the fluid at the particle
       do nc = 1, 3
          nf = UMX + (nc-1)
          fluid_vel(nc) = &
                coef_lll*state(i-1, j-1, k-1, nf)/state(i-1, j-1, k-1, URHO) + &
                coef_llh*state(i-1, j-1, k  , nf)/state(i-1, j-1, k  , URHO) + &
                coef_lhl*state(i-1, j,   k-1, nf)/state(i-1, j,   k-1, URHO) + &
                coef_lhh*state(i-1, j,   k  , nf)/state(i-1, j,   k  , URHO) + &
                coef_hll*state(i,   j-1, k-1, nf)/state(i,   j-1, k-1, URHO) + &
                coef_hlh*state(i,   j-1, k  , nf)/state(i,   j-1, k  , URHO) + &
                coef_hhl*state(i,   j,   k-1, nf)/state(i,   j,   k-1, URHO) + &
                coef_hhh*state(i,   j,   k  , nf)/state(i,   j,   k  , URHO)
       end do

       do kloc = 0,1
       do jloc = 0,1
       do iloc = 0,1

          ii = iloc-1
          jj = jloc-1
          kk = kloc-1
          eos_state % rho = state(i+ii,j+jj,k+kk,URHO)
          eos_state % T   = state(i+ii,j+jj,k+kk,UTEMP) ! Initial guess for the EOS
          eos_state % e   = state(i+ii,j+jj,k+kk,UEINT)           / state(i+ii,j+jj,k+kk,URHO)

          do ispec_loc = 1,nspec
            if(state(i+ii,j+jj,k+kk,UFS+ispec_loc-1).lt.-0.00001) then
              print *,"ciccio",ispec_loc,state(i+ii,j+jj,k+kk,UFS+ispec_loc-1)
            endif
          enddo

          eos_state % massfrac = state(i+ii,j+jj,k+kk,UFS:UFS+nspec-1)/ state(i+ii,j+jj,k+kk,URHO)

          call eos_re(eos_state)
          rholoc(iloc,jloc,kloc) =  eos_state % rho
          Tloc(iloc,jloc,kloc) =  eos_state % T
          Yloc(iloc,jloc,kloc,1:nspec) =  eos_state % massfrac

       enddo
       enddo
       enddo

       fluid_dens = &
             coef_lll*rholoc(0,0,0) + &
             coef_llh*rholoc(0,0,1) + &
             coef_lhl*rholoc(0,1,0) + &
             coef_lhh*rholoc(0,1,1) + &
             coef_hll*rholoc(1,0,0) + &
             coef_hlh*rholoc(1,0,1) + & 
             coef_hhl*rholoc(1,1,0) + &
             coef_hhh*rholoc(1,1,1) 

       if(fluid_dens.ne.fluid_dens.or.fluid_dens.le.0d0) then
         print *,'PARTICLE ID ', particles(n)%id, &
          'list',n,' corrupted field density ',fluid_dens,i,j
         stop
       endif

       fluid_temp = &
             coef_lll*Tloc(0,0,0) + &
             coef_llh*Tloc(0,0,1) + &
             coef_lhl*Tloc(0,1,0) + &
             coef_lhh*Tloc(0,1,1) + &
             coef_hll*Tloc(1,0,0) + &
             coef_hlh*Tloc(1,0,1) + & 
             coef_hhl*Tloc(1,1,0) + &
             coef_hhh*Tloc(1,1,1) 

       if(fluid_temp.ne.fluid_temp.or.fluid_temp.le.0d0) then
         print *,'PARTICLE ID ', particles(n)%id, &
          'list',n,' corrupted field temperature ',fluid_temp,i,j
         stop
       endif

       fluid_Y = &
             coef_lll*Yloc(0,0,0,1:nspec) + &
             coef_llh*Yloc(0,0,1,1:nspec) + &
             coef_lhl*Yloc(0,1,0,1:nspec) + &
             coef_lhh*Yloc(0,1,1,1:nspec) + &
             coef_hll*Yloc(1,0,0,1:nspec) + &
             coef_hlh*Yloc(1,0,1,1:nspec) + &
             coef_hhl*Yloc(1,1,0,1:nspec) + &
             coef_hhh*Yloc(1,1,1,1:nspec)

       do M = 1,nspec
         if(fluid_Y(M).ne.fluid_Y(M)) then
          print *,'PARTICLE ID ', particles(n)%id, &
          'list',n,' corrupted fuel mass fraction ',fluid_Y(M),i,j
          stop
         end if 
         fluid_Y(M) = max(fluid_Y(M),0d0)
         fluid_Y(M) = min(fluid_Y(M),1d0)
       end do
       eos_state % massfrac = fluid_Y
       eos_state % rho = fluid_dens
       eos_state % T   = fluid_temp

       call eos_rt(eos_state)
       call eos_wb(eos_state)

       fluid_pres = eos_state % p
       fluid_molwt(n) = eos_state%wbar

       ! Calculate the skin temperature of the droplet 1/3 rule.
       temp_diff(n) = fluid_temp - particles(n)%temp
       temp_skin(n) = particles(n)%temp + one_third*(temp_diff(n))

       ! Compute mu, lambda, D, cp at skin temperature 
       lo(1:3) = 1
       hi(1:3) = 1
       Y_dummy(1,1,1,1:nspec) = fluid_Y
       T_dummy(1,1,1) = temp_skin(n)
       r_dummy(1,1,1) = fluid_dens
       ! massfrac(mf_lo(1):mf_hi(1),mf_lo(2):mf_hi(2),mf_lo(3):mf_hi(3),nspec)
       ! D(D_lo(1):D_hi(1),D_lo(2):D_hi(2),D_lo(3):D_hi(3),nspec)
       ! mu(mu_lo(1):mu_hi(1),mu_lo(2):mu_hi(2),mu_lo(3):mu_hi(3))
       call get_transport_coeffs (lo, hi, &
                                 Y_dummy, lo, hi, &
                                 T_dummy, lo, hi,&
                                 r_dummy, lo, hi,&
                                 D_dummy, lo, hi, &
                                 mu_dummy, lo, hi, &
                                 xi_dummy, lo, hi, &
                                 la_dummy, lo, hi)

       D_skin(n,1:nspec_f) = D_dummy(1,1,1,fuel_indx(1:nspec_f)) ! now in kg/cm^3 cm^2/s
       visc = 1.827d-4          ! nominal value of fluid viscosity in cgs
       mu_skin(n) = mu_dummy(1,1,1)
       xi_skin(n) = xi_dummy(1,1,1)
       lambda_skin(n) = la_dummy(1,1,1)

       ! ****************************************************
       ! Source terms by individual drop
       ! ****************************************************

       diff_u = fluid_vel(1)-particles(n)%vel(1)
       diff_v = fluid_vel(2)-particles(n)%vel(2)
       diff_w = fluid_vel(3)-particles(n)%vel(3)

       diff_velmag = sqrt( diff_u**2 + diff_v**2 + diff_w**2)

       ! Local Reynolds number = (Density * Relative Velocity) * (Particle Diameter) / (Viscosity)
       reyn = fluid_dens*diff_velmag*particles(n)%diam/visc

       ! Time constant.
       inv_tau(n) = (18.0d0*mu_skin(n))/(particles(n)%density*particles(n)%diam**2)

       drag_coef = 1.0d0+0.15d0*reyn**(0.687d0)

       ! Drag coefficient =  (pi / 8) * (Density * Relative Velocity) * (Particle Diameter)**2
       drag = 0.125d0*pi*(particles(n)%diam)**2 *fluid_dens*diff_velmag

       force(1) = drag*diff_u
       force(2) = drag*diff_v
       force(3) = drag*diff_w

       !individual fuel species cp, based on skin temperature 
       !and gas_phase mass fractions.
       !subroutine calc_spec_mix_cp_spray (n_part,massfrac,temp,mix_cp,fuel_spec_cp)
       call calc_spec_mix_cp_spray(eos_state, &
                                   fluid_Y, temp_skin(n), &
                                   cp_skin(n), cp_f(n,1:nspec_f))

       pmass = pi_six*particles(n)%density*particles(n)%diam**3

       m_dot = 0.0d0
       Y_dot = 0.0d0
       d_dot = 0.0d0
       convection = 0.0d0
       L_fuel = 0.0d0
       is_to_skip = 0
       do M = 1,nspec
        if(fluid_Y(M).ge.1d0) then ! the gas phase is only fuel vapor
         is_to_skip = 1
        endif 
       end do 

       if(is_mass_tran.eq.1.and.is_to_skip.eq.0) then
 
         ! LOOP THROUGH ALL THE FUEL SPECIES AND GET THE INDIVIDUAL
         ! EVAPORATION RATES.
         do L = 1,nspec_f

           ! Calculate Skin Schmidt Number.
           Sc_skin(n,L) = mu_skin(n)/(D_skin(n,L))

           ! CALCULATE THE LATENT HEAT
           ! First term RHS is the enthalpy of the vapor at the skin
           ! temperature
           ! Second term RHM is the enthalpy of the liquid droplet (h0_f + cp dT)
           ! The h0_f is for the liquid phase. 
           call calc_fuel_latent(fuel_crit_temp(L),inv_diff_temp(L),fuel_latent(L),&
                particles(n)%temp,L_fuel(L))

           if (L_fuel(L).ne.L_fuel(L)) then 
             print *,'PARTICLE ID ', particles(n)%temp,' temp BUST ',L_fuel(1),inv_diff_temp(L),fuel_latent(L)
             stop
           endif

           ! CALCULATE THE SPALDING NUMBER
           call calc_spalding_num(L_fuel(L),particles(n)%temp,fluid_pres,&
                                  fluid_Y(fuel_indx(L)),fluid_molwt(n),fuel_molwt(L),&
                                  invfmolwt(L), inv_boil_temp(L),inv_Ru, p0, &
                                  spalding_B(n,L))

           ! CALCULATE Y_dot (mass/time) FOR EACH SPECIES 
           call calc_spec_evap_rate(particles(n)%diam,spalding_B(n,L),reyn,&
                                    Sc_skin(n,L),D_skin(n,L),Sh(n,L),Y_dot(L))

           ! Total mass transfer is sum of individual species transfer (in g/s)
           m_dot = m_dot + Y_dot(L)

           if (abs(Y_dot(L)).gt.2e-5) then 
             print *,'PARTICLE ID ', particles(n)%id,' Y_dot',Y_dot(L),spalding_B(n,L),reyn,&
                                     Sc_skin(n,L),D_skin(n,L),Sh(n,L)
           endif
        end do ! do L

        ! Diameter rate of change (d_dot)
        d_dot = m_dot/(half_pi*particles(n)%density*particles(n)%diam**2)
        if (d_dot.ne.d_dot) then 
          print *,'PARTICLE ID ', particles(n)%id,' d_dot BUST ',m_dot,particles(n)%diam
          stop
        endif

       endif ! if(is_mass_tran.eq.1)

!      part_source(is:ie,1) = (m_d*v_dot(is:ie,1)+m_dot*vel_d(is:ie,1))
!      part_source(is:ie,1) = (m_d*v_dot(is:ie,1)+m_dot*vel_d(is:ie,1))
!      part_source(is:ie,4) = sum(vel_d(is:ie,:)*v_dot(is:ie,:),DIM=2)*m_d(is:ie)
!      part_source(is:ie,4) = part_source(is:ie,4)+m_d(is:ie)*cp_d_av(is:ie)*&
!                             convection(is:ie)


!-----------------------------------------------------------------------------------------
! CALCULATE TEMPERATURE RATE OF CHANGE: psrc_T_d(is:ie)

       heat_src = 0d0
       if((is_heat_tran.eq.1 .or. is_mass_tran.eq.1.).and.is_to_skip.eq.0) then

         !-----------------------------------------------------------------------------------------
         ! Calculate Skin Prandtl Number.
         Pr_skin(n) = mu_skin(n)*cp_skin(n)/lambda_skin(n)
         ! compare to prandtl = 0.75d0

         ! Calculate the time constant for conduction
         ! Take the reciprocal save some flops.
         inv_cp_d = 1.0d0/(cp_d_av*pmass*Pr_skin(n))

         ! Calculate energy transfer due to heat transfer and evaporation
         do L = 1,nspec_f

           ! Calculate Nusselt Number (Uncorrected)
           Nu(n) = 1.0d0+max(reyn**0.077,1.0d0)*(1.0d0+reyn*Pr_skin(n))**one_third ! Eq. (21)

           ! Calculate Spalding Heat transfer number (B_T) and the corrected
           ! nusselt number
           call calc_thermal_B(Nu(n), Sh(n,L), Pr_skin(n), Sc_skin(n,L), &
                cp_f(n,L), cp_skin(n), spalding_B(n,L), B_T(n,L))

           tmp_conv = temp_diff(n)*one_third*inv_cp_d*cp_skin(n)*pmass*&
                      Nu(n)*inv_tau(n)

           convection = convection + tmp_conv
           if (temp_skin(n).ne.temp_skin(n)) then 
             print *,'TEMPSKIN ', temp_skin(n)
             stop
           endif

           ! Calculate energy needed to raise temperature of vapor. Why the
           ! liquid phase values?
           ! call calc_skin_enth(n,nspec_f,fuel_indx(L),particles(n)%temp,temp_skin(n),&
           ! L_fuel(L),h_skin(L))
           ! This is with enthalpy of the vapor phase
           !h_skin(L) = -cp_f(n,L)*(temp_skin(n)-particles(n)%temp)+L_fuel(L)
           h_skin(L) = cp_f(n,L)*(temp_skin(n)-particles(n)%temp)+L_fuel(L)
           !h_skin(L) = -1.5e7*(temp_skin(n)-particles(n)%temp)+L_fuel(L)

         end do ! do L

         ! Add mass transfer term
         heat_src = convection+&
                    sum(Y_dot*h_skin,DIM=nspec_f)*inv_cp_d*Pr_skin(n)
         !          sum(Y_dot*L_fuel,DIM=nspec_f)*inv_cp_d*Pr_skin(n)
           if (heat_src.ne.heat_src) then 
             print *,'PARTICLE ID ', particles(n)%temp,' temp BUST ',L_fuel(1)
             stop
           endif

       endif ! if(is_heat_tran.eq.1 .or. is_mass_tran.eq.1) 

       ! ****************************************************
       ! Put the same forcing term on the grid (cell centers)
       ! ****************************************************

       if(is_mom_tran.eq.1.or.is_mass_tran.eq.1.or.is_heat_tran.eq.1) then

          lx2 = (particles(n)%pos(1) - plo(1))*inv_dx(1) - 0.5d0
          ly2 = (particles(n)%pos(2) - plo(2))*inv_dx(2) - 0.5d0
          lz2 = (particles(n)%pos(3) - plo(3))*inv_dx(3) - 0.5d0

          i2 = floor(lx2)
          j2 = floor(ly2)
          k2 = floor(lz2)

          wx_hi = lx2 - i2
          wy_hi = ly2 - j2
          wz_hi = lz2 - k2

          wx_lo = 1.0d0 - wx_hi
          wy_lo = 1.0d0 - wy_hi
          wz_lo = 1.0d0 - wz_hi
  
          ! These are the coefficients for the deposition of sources from particle locations to the fields
          coef_lll = (wx_lo * wy_lo * wz_lo) * inv_vol
          coef_hll = (wx_hi * wy_lo * wz_lo) * inv_vol
          coef_lhl = (wx_lo * wy_hi * wz_lo) * inv_vol
          coef_hhl = (wx_hi * wy_hi * wz_lo) * inv_vol
          coef_llh = (wx_lo * wy_lo * wz_hi) * inv_vol
          coef_hlh = (wx_hi * wy_lo * wz_hi) * inv_vol
          coef_lhh = (wx_lo * wy_hi * wz_hi) * inv_vol
          coef_hhh = (wx_hi * wy_hi * wz_hi) * inv_vol

       if (i2 .lt. source_lo(1) .or. i2 .gt. source_hi(1)-1 .or. &
           j2 .lt. source_lo(2) .or. j2 .gt. source_hi(2)-1 .or. &
           k2 .lt. source_lo(3) .or. k2 .gt. source_hi(3)-1) then
          print *,'PARTICLE ID ', particles(n)%id,' TOUCHING SOURCE OUT OF BOUNDS AT (I,J,K) = ',i,j,k
          print *,'Array bounds are ', source_lo(:), source_hi(:)
          print *,'(x,y,z) are ', particles(n)%pos(1), particles(n)%pos(2), particles(n)%pos(3)
       !  call bl_error('Aborting in update_particles')
       endif
 
       endif
       ! Force component "nc" is component "nf" in the ordering of (URHO, UMX, UMY, ...)
       if(is_mass_tran.eq.1) then
          nf = UFS + fuel_indx(1)-1
          source(i2,   j2  ,k2  ,nf) = source(i2,   j2  ,k2  ,nf) - coef_lll*Y_dot(1)
          source(i2,   j2+1,k2  ,nf) = source(i2,   j2+1,k2  ,nf) - coef_lhl*Y_dot(1)
          source(i2+1, j2  ,k2  ,nf) = source(i2+1, j2  ,k2  ,nf) - coef_hll*Y_dot(1)
          source(i2+1, j2+1,k2  ,nf) = source(i2+1, j2+1,k2  ,nf) - coef_hhl*Y_dot(1)
          source(i2,   j2  ,k2+1,nf) = source(i2,   j2  ,k2+1,nf) - coef_llh*Y_dot(1)
          source(i2,   j2+1,k2+1,nf) = source(i2,   j2+1,k2+1,nf) - coef_lhh*Y_dot(1)
          source(i2+1, j2  ,k2+1,nf) = source(i2+1, j2  ,k2+1,nf) - coef_hlh*Y_dot(1)
          source(i2+1, j2+1,k2+1,nf) = source(i2+1, j2+1,k2+1,nf) - coef_hhh*Y_dot(1)
       endif

       kinetic_src = 0d0
       if(is_mom_tran.eq.1) then
          do nc = 1, 3
             nf = UMX + (nc-1)
             source(i2,   j2  ,k2  ,nf) = source(i2,   j2  ,k2  ,nf) - coef_lll*force(nc)
             source(i2,   j2+1,k2  ,nf) = source(i2,   j2+1,k2  ,nf) - coef_lhl*force(nc)
             source(i2+1, j2  ,k2  ,nf) = source(i2+1, j2  ,k2  ,nf) - coef_hll*force(nc)
             source(i2+1, j2+1,k2  ,nf) = source(i2+1, j2+1,k2  ,nf) - coef_hhl*force(nc)
             source(i2,   j2  ,k2+1,nf) = source(i2,   j2  ,k2+1,nf) - coef_llh*force(nc)
             source(i2,   j2+1,k2+1,nf) = source(i2,   j2+1,k2+1,nf) - coef_lhh*force(nc)
             source(i2+1, j2  ,k2+1,nf) = source(i2+1, j2  ,k2+1,nf) - coef_hlh*force(nc)
             source(i2+1, j2+1,k2+1,nf) = source(i2+1, j2+1,k2+1,nf) - coef_hhh*force(nc)
          end do

          kinetic_src = force(1)*fluid_vel(1)+force(2)*fluid_vel(2)+force(3)*fluid_vel(3)
       endif

       if(is_heat_tran.eq.1) then

          source(i2,   j2  ,k2  ,UEINT) = source(i2,   j2  ,k2  ,UEINT) - coef_lll*heat_src
          source(i2,   j2+1,k2  ,UEINT) = source(i2,   j2+1,k2  ,UEINT) - coef_lhl*heat_src
          source(i2+1, j2  ,k2  ,UEINT) = source(i2+1, j2  ,k2  ,UEINT) - coef_hll*heat_src
          source(i2+1, j2+1,k2  ,UEINT) = source(i2+1, j2+1,k2  ,UEINT) - coef_hhl*heat_src
          source(i2,   j2  ,k2+1,UEINT) = source(i2,   j2  ,k2+1,UEINT) - coef_llh*heat_src
          source(i2,   j2+1,k2+1,UEINT) = source(i2,   j2+1,k2+1,UEINT) - coef_lhh*heat_src
          source(i2+1, j2  ,k2+1,UEINT) = source(i2+1, j2  ,k2+1,UEINT) - coef_hlh*heat_src
          source(i2+1, j2+1,k2+1,UEINT) = source(i2+1, j2+1,k2+1,UEINT) - coef_hhh*heat_src

          source(i2  ,j2  ,k2  ,UEDEN) = source(i2  ,j2  ,k2  ,UEDEN) - coef_lll*( &
                     heat_src + kinetic_src )

          source(i2+1,j2  ,k2  ,UEDEN) = source(i2+1,j2  ,k2  ,UEDEN) - coef_hll*( &
                     heat_src + kinetic_src )

          source(i2  ,j2+1,k2  ,UEDEN) = source(i2  ,j2+1,k2  ,UEDEN) - coef_lhl* ( &
                     heat_src + kinetic_src )

          source(i2+1,j2+1,k2  ,UEDEN) = source(i2+1,j2+1,k2  ,UEDEN) - coef_hhl* ( &
                     heat_src + kinetic_src )

          source(i2  ,j2  ,k2+1,UEDEN) = source(i2  ,j2  ,k2+1,UEDEN) - coef_llh* ( &
                     heat_src + kinetic_src )

          source(i2+1,j2  ,k2+1,UEDEN) = source(i2+1,j2  ,k2+1,UEDEN) - coef_hlh* ( &
                     heat_src + kinetic_src )
  
          source(i2  ,j2+1,k2+1,UEDEN) = source(i2  ,j2+1,k2+1,UEDEN) - coef_lhh* ( &
                     heat_src + kinetic_src )

          source(i2+1,j2+1,k2+1,UEDEN) = source(i2+1,j2+1,k2+1,UEDEN) - coef_hhh* ( &
                     heat_src + kinetic_src )

       endif

       ! ****************************************************
       ! Now apply the forcing term to the particles
       ! ****************************************************

       do nc = 1, 3
          ! Update velocity by half dt
          particles(n)%vel(nc) = particles(n)%vel(nc) + half_dt * force(nc) / pmass

          ! Update position by full dt
          if (do_move .eq. 1) &
             particles(n)%pos(nc) =particles(n)%pos(nc) + dt * particles(n)%vel(nc) 
       end do

       ! consider changing to lagged temperature to improve order
       delta_T =  half_dt * heat_src / (cp_d_av*pmass)
       if(abs(delta_T).gt.3d0) then 
          print *,'PARTICLE ID ', particles(n)%id,' delta T',delta_T,particles(n)%diam
          !delta_T = 0d0
       endif

       particles(n)%temp = particles(n)%temp + delta_T
 
       ! Update diameter by half dt
       particles(n)%diam = particles(n)%diam + half_dt * d_dot

       if (particles(n)%diam .lt. 1e-6) then ! arbitrary theeshold size
          print *,'PARTICLE ID ', particles(n)%id,' REMOVED'
          print *,'had pos',particles(n)%pos(1),particles(n)%pos(2),particles(n)%pos(3)
          print *,'had vel',particles(n)%vel(1),particles(n)%vel(2),particles(n)%vel(3)
          particles(n)%id = -1
       endif

     endif

    end do ! do n

    ! We are at the lo-x boundary and it is a reflecting wall
    if (source_lo(1) .lt. domlo(1) .and. reflect_lo(1) .eq. 1) then
       do k = source_lo(3),source_hi(3)
       do j = source_lo(2),source_hi(2)
          source(domlo(1),j,k,:) = source(domlo(1),j,k,:) + source(domlo(1)-1,j,k,:)
       end do
       end do
    end if

    if (source_lo(2) .lt. domlo(2) .and. reflect_lo(2) .eq. 1) then
       ! We are at the lo-y boundary and it is a reflecting wall
       do k = source_lo(3),source_hi(3)
       do i = source_lo(1),source_hi(1)
          source(i,domlo(2),k,:) = source(i,domlo(2),k,:) + source(i,domlo(2)-1,k,:)
       end do
       end do
    end if

    if (source_lo(3) .lt. domlo(3) .and. reflect_lo(3) .eq. 1) then
       ! We are at the lo-z boundary and it is a reflecting wall
        do k = source_lo(3),source_hi(3)
        do j = source_lo(2),source_hi(2)
           source(i,j,domlo(3),:) = source(i,j,domlo(3),:) + source(i,j,domlo(3)-1,:)
        end do
        end do
    end if

    if (source_hi(1) .gt. domhi(1) .and. reflect_hi(1) .eq. 1) then
       ! We are at the hi-x boundary and it is a reflecting wall
       do k = source_lo(3),source_hi(3)
       do j = source_lo(2),source_hi(2)
          source(domhi(1),j,k,:) = source(domhi(1),j,k,:) + source(domhi(1)+1,j,k,:)
       end do
       end do
    end if

    if (source_hi(2) .gt. domhi(2) .and. reflect_hi(2) .eq. 1) then
       ! We are at the hi-y boundary and it is a reflecting wall
       do k = source_lo(3),source_hi(3)
       do i = source_lo(1),source_hi(1)
          source(i,domhi(2),k,:) = source(i,domhi(2),k,:) + source(i,domhi(2)+1,k,:)
       end do
       end do
    end if

    if (source_hi(3) .gt. domhi(3) .and. reflect_hi(3) .eq. 1) then
       ! We are at the hi-z boundary and it is a reflecting wall
       do j = source_lo(2),source_hi(2)
       do i = source_lo(1),source_hi(1)
          source(i,j,domhi(3),:) = source(i,j,domhi(3),:) + source(i,j,domhi(3)+1,:)
       end do
       end do
    end if

    if (do_move .eq. 1) then

       ! If at a reflecting boundary (Symmetry or Wall), 
       ! flip the position back into the domain and flip the sign of the normal velocity 
 
       do nc = 1, 3

          if (reflect_lo(nc) .eq. 1) then
             do n = 1, np
                if (particles(n)%pos(nc) .lt. plo(nc)) then
                    particles(n)%pos(nc) = 2.d0*plo(nc) - particles(n)%pos(nc) 
                    particles(n)%vel(nc) = -particles(n)%vel(nc) 
                end if
             end do
          end if
          if (reflect_hi(nc) .eq. 1) then
             do n = 1, np
                if (particles(n)%pos(nc) .lt. plo(nc)) then
                    particles(n)%pos(nc) = 2.d0*phi(nc)-particles(n)%pos(nc) 
                    particles(n)%vel(nc) = -particles(n)%vel(nc) 
                end if
             end do
          end if

       end do

    end if

    call destroy(eos_state)

  end subroutine update_particles

end module drag_module
