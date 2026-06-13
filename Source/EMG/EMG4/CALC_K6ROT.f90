! #################################################################################################################################
! Begin MIT license text.
! _______________________________________________________________________________________________________

! Copyright 2022 Dr William R Case, Jr (mystransolver@gmail.com)

! Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
! associated documentation files (the "Software"), to deal in the Software without restriction, including
! without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
! copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to
! the following conditions:

! The above copyright notice and this permission notice shall be included in all copies or substantial
! portions of the Software and documentation.

! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
! OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
! THE SOFTWARE.
! _______________________________________________________________________________________________________

! End MIT license text.
      SUBROUTINE CALC_K6ROT ()

! Builds the stiffness matrix for a spring connecting the drilling DOF to the translational DOFs of the adjacent nodes
! of the element. Adds that to the existing stiffness matrix KE in the element coordinate system.

      USE PENTIUM_II_KIND, ONLY       :  LONG, DOUBLE
      USE MODEL_STUF, ONLY            :  TYPE, ELGP, INTL_MID, XEL, SHELL_A, KE
      USE MITC_STUF, ONLY             :  DIRECTOR
      USE PARAMS, ONLY                :  K6ROT, QUAD4TYP
      USE CONSTANTS_1, ONLY           :  ZERO, ONE
      USE SCONTR, ONLY                :  MAX_ORDER_GAUSS

      IMPLICIT NONE

      REAL(DOUBLE)                    :: K6_DIR(3,ELGP)       ! Normalized direction of the singular DOF (spring x axis).
      REAL(DOUBLE)                    :: T(3,3)               ! Transformation matrix for spring.
      REAL(DOUBLE)                    :: KROT(3,3)            ! Stiff matrix for spring.
      REAL(DOUBLE)                    :: AREA                 ! Elem area
      REAL(DOUBLE)                    :: DETJ                 ! An output from subr JAC2D4, called herein. Determinant of JAC
      INTEGER(LONG)                   :: I,J,K
      REAL(DOUBLE)                    :: JAC(2,2)             ! An output from subr JAC2D4, called herein. 2 x 2 Jacobian matrix.
      REAL(DOUBLE)                    :: JACI(2,2)            ! An output from subr JAC2D4, called herein. 2 x 2 Jacobian inverse.
      REAL(DOUBLE)                    :: Ksita             ! virtual rotational stiffness derived from K6ROT
      REAL(DOUBLE)                    :: X2E               ! x coord of elem node 2
      REAL(DOUBLE)                    :: Y3E               ! y coord of elem node 3
      REAL(DOUBLE)                    :: XSD(4)               ! Diffs in x coords of quad sides in local coords
      REAL(DOUBLE)                    :: YSD(4)               ! Diffs in y coords of quad sides in local coords
      REAL(DOUBLE)                    :: HHH(MAX_ORDER_GAUSS) ! An output from subr ORDER, called herein.  Gauss weights.
      REAL(DOUBLE)                    :: SSS(MAX_ORDER_GAUSS) ! An output from subr ORDER, called herein. Gauss abscissa's.

! **********************************************************************************************************************************

! **********************************************************************************************************************************
! Add K6ROT stiffness


                                                     ! No K6ROT for shells that only use MID1.
      IF (INTL_MID(2) > 0) THEN

         AREA = ZERO

         IF ((TYPE(1:5) == "QUAD4")) THEN

            XSD(1) = XEL(1,1) - XEL(2,1)             ! x coord diffs (in local elem coords)
            XSD(2) = XEL(2,1) - XEL(3,1)
            XSD(3) = XEL(3,1) - XEL(4,1)
            XSD(4) = XEL(4,1) - XEL(1,1)

            YSD(1) = XEL(1,2) - XEL(2,2)             ! y coord diffs (in local elem coords)
            YSD(2) = XEL(2,2) - XEL(3,2)
            YSD(3) = XEL(3,2) - XEL(4,2)
            YSD(4) = XEL(4,2) - XEL(1,2)

            CALL ORDER_GAUSS ( 2, SSS, HHH )
            DO I=1,2
               DO J=1,2
                  CALL JAC2D ( SSS(I), SSS(J), XSD, YSD, 'N', JAC, JACI, DETJ )
                  AREA = AREA + HHH(I)*HHH(J)*DETJ
               ENDDO
            ENDDO

         ELSEIF (TYPE(1:5) == "TRIA3") THEN

            X2E  = XEL(2,1)
            Y3E  = XEL(3,2)
                                                     ! Actual area is half this but using this value
                                                     ! gives the same stiffness as MSC.
            AREA = X2E*Y3E

         ENDIF

         ! Drilling spring stiffness = K6ROT * 10^-6 * G12 * thickness * area
         !                           = K6ROT * 10^-6 * A(3,3) * area
         Ksita = 10.0**(-6.0) * SHELL_A(3,3) * ABS(AREA) * K6ROT

         ! Find the direction of the singularity DOF (SNORM) in the element coordinate system.
         IF ((TYPE == 'QUAD4   ') .AND. ((QUAD4TYP == 'MITC4 ') .OR. (QUAD4TYP == 'MITC4+'))) THEN
                                                     ! This is currently the director vector
                                                     ! but it won't be if SNORM is implemented
                                                     ! without changing the geometry of the element.
            K6_DIR(:,1:ELGP) = DIRECTOR(:,1:ELGP)
         ELSEIF (((TYPE == 'QUAD4   ') .AND. ((QUAD4TYP == 'MIN4  ') .OR. (QUAD4TYP == 'MIN4T ')))                           &
           .OR.   (TYPE == 'TRIA3   ')) THEN
                                                     ! Spring axis is simply the element z axis.
            K6_DIR(1,:) = ZERO
            K6_DIR(2,:) = ZERO
            K6_DIR(3,:) = ONE
         ENDIF

         DO J=1,ELGP

            ! Spring stiffness matrix where stiffness is in the spring x direction
            !
            !        [ Ksita   0     0  ]
            ! KROT = [   0     0     0  ]
            !        [   0     0     0  ]
            KROT(:,:) = ZERO
            KROT(1,1) = Ksita

            ! Transformation matrix from spring coordinates to element coordinates
            ! Spring x is the singularity axis
            T(:,1) = K6_DIR(:,J)
            ! Spring y is orthogonal to both spring x and element x
            CALL CROSS(T(:,1), (/ ONE, ZERO, ZERO /), T(:,2))
            ! Normalize spring y
            T(:,2) = T(:,2) / DSQRT(DOT_PRODUCT(T(:,2), T(:,2)))
            ! Spring z is mutually orthogonal
            CALL CROSS(T(:,1), T(:,2), T(:,3))

            ! Transform the spring stiffness matrix to element coordinates.
            ! T * K * T'
            KROT = MATMUL(MATMUL(T, KROT), TRANSPOSE(T))

            ! Add the 3x3 spring stiffness matrix to the element stiffness matrix
            K = (J-1) * 6
            KE(K+4:K+6,K+4:K+6) = KE(K+4:K+6,K+4:K+6) + KROT(:,:)

            ! todo remove.
            ! Spring axis is element coordinate z axis. Only correct for flat elements without SNORM.
            ! KE(6*J,6*J) = KE(6*J,6*J) + Ksita

         ENDDO

      ENDIF
    

! **********************************************************************************************************************************


! **********************************************************************************************************************************

      END SUBROUTINE CALC_K6ROT
