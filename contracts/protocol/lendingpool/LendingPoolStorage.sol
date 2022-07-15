// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

import {UserConfiguration} from '../libraries/configuration/UserConfiguration.sol';
import {ReserveConfiguration} from '../libraries/configuration/ReserveConfiguration.sol';
import {ReserveLogic} from '../libraries/logic/ReserveLogic.sol';
import {ILendingPoolAddressesProvider} from '../../interfaces/ILendingPoolAddressesProvider.sol';
import {DataTypes} from '../libraries/types/DataTypes.sol';

contract LendingPoolStorage {
  using ReserveLogic for DataTypes.ReserveData;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using UserConfiguration for DataTypes.UserConfigurationMap;

  // Asset의 주소나 LendingPool의 주소, Admin의 계좌 주소 등에 대한 주소 정보를 주기 위한 컨트랙트
  ILendingPoolAddressesProvider internal _addressesProvider;

  // DataTypes 내부 구조 분석하고 나서 코멘트 다는 것으로 보류
  mapping(address => DataTypes.ReserveData) internal _reserves;
  // 해당 부분도 DataTypes 분석 되면 그때 코멘트 달 예정
  mapping(address => DataTypes.UserConfigurationMap) internal _usersConfig;

  // the list of the available reserves, structured as a mapping for gas savings reasons
  mapping(uint256 => address) internal _reservesList;

  // LendingPool에 예약된 토큰이 총 몇개인지를 확인하는 코드
  uint256 internal _reservesCount;

  // 해당 LendingPool이 현재 정지 상태인지 아닌지를 확인하는 변수
  bool internal _paused;

  // 대출 고정 금리에 대한 최대 수치를 나타내는 변수
  uint256 internal _maxStableRateBorrowSizePercent;

  // Flash Loan에 대해서는 조금 더 공부해야함
  uint256 internal _flashLoanPremiumTotal;

  // 최대로 LendingPool이 유지할 수 있는 토큰 컨트랙트의 최대 수
  uint256 internal _maxNumberOfReserves;
}
