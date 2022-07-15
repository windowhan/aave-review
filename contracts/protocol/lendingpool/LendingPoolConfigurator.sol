// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeMath} from '../../dependencies/openzeppelin/contracts/SafeMath.sol';
import {VersionedInitializable} from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import {
  InitializableImmutableAdminUpgradeabilityProxy
} from '../libraries/aave-upgradeability/InitializableImmutableAdminUpgradeabilityProxy.sol';
import {ReserveConfiguration} from '../libraries/configuration/ReserveConfiguration.sol';
import {ILendingPoolAddressesProvider} from '../../interfaces/ILendingPoolAddressesProvider.sol';
import {ILendingPool} from '../../interfaces/ILendingPool.sol';
import {IERC20Detailed} from '../../dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {PercentageMath} from '../libraries/math/PercentageMath.sol';
import {DataTypes} from '../libraries/types/DataTypes.sol';
import {IInitializableDebtToken} from '../../interfaces/IInitializableDebtToken.sol';
import {IInitializableAToken} from '../../interfaces/IInitializableAToken.sol';
import {IAaveIncentivesController} from '../../interfaces/IAaveIncentivesController.sol';
import {ILendingPoolConfigurator} from '../../interfaces/ILendingPoolConfigurator.sol';

/**
 * @title LendingPoolConfigurator contract
 * @author Aave
 * @dev Implements the configuration methods for the Aave protocol
 **/

contract LendingPoolConfigurator is VersionedInitializable, ILendingPoolConfigurator {
  using SafeMath for uint256;
  using PercentageMath for uint256;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  ILendingPoolAddressesProvider internal addressesProvider;
  ILendingPool internal pool;

  modifier onlyPoolAdmin {
    require(addressesProvider.getPoolAdmin() == msg.sender, Errors.CALLER_NOT_POOL_ADMIN);
    _;
  }

  // Emergency Admin의 경우 Pool Admin과 동일할 수도 있지만 아닐 수도 있음
  // 만약 어드민 계정을 분실해서 컨트랙트에 대한 관리가 불가능할 경우 해당 Emergency Admin을 활용하여
  // 예비로 컨트랙트에 대한 관리 권한을 얻을 수 있음
  modifier onlyEmergencyAdmin {
    require(
      addressesProvider.getEmergencyAdmin() == msg.sender,
      Errors.LPC_CALLER_NOT_EMERGENCY_ADMIN
    );
    _;
  }

  uint256 internal constant CONFIGURATOR_REVISION = 0x1;

  function getRevision() internal pure override returns (uint256) {
    return CONFIGURATOR_REVISION;
  }

  // 여기서 제공되는 initializer modifier의 경우 생성자, 그리고 initializing 과정에서만 호출이 가능하며
  // lastInitializedRevision 버전보다 revision 버전이 높은 경우에만 초기화를 수행할 수 있도록 지정해준
  // modifier임
  function initialize(ILendingPoolAddressesProvider provider) public initializer {
    // LendingPoolAddressesProvider와 LendingPoolConfigurator는 서로 의존적인 관계
    addressesProvider = provider;
    // pool은 LendingPool의 인스턴스가 저장되는데 이는 Deposit, Borrow, Rate swap 등의 기능을 제공하는
    // 어떻게보면 프로토콜의 본체와 같은 기능을 담당하는 부분
    pool = ILendingPool(addressesProvider.getLendingPool());
  }

  /**
   * @dev Initializes reserves in batch
   **/
  // 한 번에 여러 개의 Reserve들을 등록하기 위해 있는 함수
  function batchInitReserve(InitReserveInput[] calldata input) external onlyPoolAdmin {
    ILendingPool cachedPool = pool;
    for (uint256 i = 0; i < input.length; i++) {
      _initReserve(cachedPool, input[i]);
    }
  }

  // _initReserve 함수는 asset에 해당하는 토큰을 등록하기 위한 함수, pool 또한 지정되어 제공됨
  // Reserve 들은 전부 LendingPool에 대기하고 있다가 사용자의 인터랙션이 들어오면
  // 해당 Pool에서 사용자의 요청에 맞는 Asset을 찾아 처리하는 형식
  function _initReserve(ILendingPool pool, InitReserveInput calldata input) internal {
    address aTokenProxyAddress =
      _initTokenWithProxy(
        input.aTokenImpl,
        abi.encodeWithSelector(
          IInitializableAToken.initialize.selector,
          pool,
          input.treasury,
          input.underlyingAsset,
          IAaveIncentivesController(input.incentivesController),
          input.underlyingAssetDecimals,
          input.aTokenName,
          input.aTokenSymbol,
          input.params
        )
      );

    address stableDebtTokenProxyAddress =
      _initTokenWithProxy(
        input.stableDebtTokenImpl,
        abi.encodeWithSelector(
          IInitializableDebtToken.initialize.selector,
          pool,
          input.underlyingAsset,
          IAaveIncentivesController(input.incentivesController),
          input.underlyingAssetDecimals,
          input.stableDebtTokenName,
          input.stableDebtTokenSymbol,
          input.params
        )
      );

    address variableDebtTokenProxyAddress =
      _initTokenWithProxy(
        input.variableDebtTokenImpl,
        abi.encodeWithSelector(
          IInitializableDebtToken.initialize.selector,
          pool,
          input.underlyingAsset,
          IAaveIncentivesController(input.incentivesController),
          input.underlyingAssetDecimals,
          input.variableDebtTokenName,
          input.variableDebtTokenSymbol,
          input.params
        )
      );

    pool.initReserve(
      input.underlyingAsset,
      aTokenProxyAddress,
      stableDebtTokenProxyAddress,
      variableDebtTokenProxyAddress,
      input.interestRateStrategyAddress
    );

    DataTypes.ReserveConfigurationMap memory currentConfig =
      pool.getConfiguration(input.underlyingAsset);

    currentConfig.setDecimals(input.underlyingAssetDecimals);

    currentConfig.setActive(true);
    currentConfig.setFrozen(false);

    pool.setConfiguration(input.underlyingAsset, currentConfig.data);

    emit ReserveInitialized(
      input.underlyingAsset,
      aTokenProxyAddress,
      stableDebtTokenProxyAddress,
      variableDebtTokenProxyAddress,
      input.interestRateStrategyAddress
    );
  }

  /**
   * @dev Updates the aToken implementation for the reserve
   **/

  // 당연히 Pool에 위치한 AToken의 정보는 PoolAdmin만 수정할 수 있기 때문에 modifier가 붙어 있음
  function updateAToken(UpdateATokenInput calldata input) external onlyPoolAdmin {
    ILendingPool cachedPool = pool;

    DataTypes.ReserveData memory reserveData = cachedPool.getReserveData(input.asset);

    (, , , uint256 decimals, ) = cachedPool.getConfiguration(input.asset).getParamsMemory();

    bytes memory encodedCall = abi.encodeWithSelector(
        IInitializableAToken.initialize.selector,
        cachedPool,
        input.treasury,
        input.asset,
        input.incentivesController,
        decimals,
        input.name,
        input.symbol,
        input.params
      );

    // _upgradeTokenImplementation으로 업데이트를 수행하는데, 내부에서는 delegatecall이나 call을 사용할듯
    _upgradeTokenImplementation(
      reserveData.aTokenAddress,
      input.implementation,
      encodedCall
    );

    emit ATokenUpgraded(input.asset, reserveData.aTokenAddress, input.implementation);
  }

  /**
   * @dev Updates the stable debt token implementation for the reserve
   **/
  // 여기서 Debt Token이란 부채 토큰의 개념으로 차입 및 상환 시에 소각되는 이자가 발생하는 토큰임
  // Compound와 다른 점은 Compound는 그때그때 바로 원본 cToken에 이자율 등을 계산하였지만
  // 여기서는 별도로 Stable Debt Token과 Variable Debt Token을 두고 관리하는 것 같음
  function updateStableDebtToken(UpdateDebtTokenInput calldata input) external onlyPoolAdmin {
    ILendingPool cachedPool = pool;

    DataTypes.ReserveData memory reserveData = cachedPool.getReserveData(input.asset);
     
    (, , , uint256 decimals, ) = cachedPool.getConfiguration(input.asset).getParamsMemory();

    bytes memory encodedCall = abi.encodeWithSelector(
        IInitializableDebtToken.initialize.selector,
        cachedPool,
        input.asset,
        input.incentivesController,
        decimals,
        input.name,
        input.symbol,
        input.params
      );

    _upgradeTokenImplementation(
      reserveData.stableDebtTokenAddress,
      input.implementation,
      encodedCall
    );

    emit StableDebtTokenUpgraded(
      input.asset,
      reserveData.stableDebtTokenAddress,
      input.implementation
    );
  }

  /**
   * @dev Updates the variable debt token implementation for the asset
   **/
  // 여기서는 Variable Debt Token을 업데이트 하기 위한 부분
  function updateVariableDebtToken(UpdateDebtTokenInput calldata input)
    external
    onlyPoolAdmin
  {
    ILendingPool cachedPool = pool;

    DataTypes.ReserveData memory reserveData = cachedPool.getReserveData(input.asset);

    (, , , uint256 decimals, ) = cachedPool.getConfiguration(input.asset).getParamsMemory();

    bytes memory encodedCall = abi.encodeWithSelector(
        IInitializableDebtToken.initialize.selector,
        cachedPool,
        input.asset,
        input.incentivesController,
        decimals,
        input.name,
        input.symbol,
        input.params
      );

    _upgradeTokenImplementation(
      reserveData.variableDebtTokenAddress,
      input.implementation,
      encodedCall
    );

    emit VariableDebtTokenUpgraded(
      input.asset,
      reserveData.variableDebtTokenAddress,
      input.implementation
    );
  }

  /**
   * @dev Enables borrowing on a reserve
   * @param asset The address of the underlying asset of the reserve
   * @param stableBorrowRateEnabled True if stable borrow rate needs to be enabled by default on this reserve
   **/
  // 이 함수는 특정 Asset에서 대출을 허용하기 위해 사용하는 함수
  // 당연히 외부에 external로 공개된 함수지만 Pool Admin만 사용이 가능한 함수
  function enableBorrowingOnReserve(address asset, bool stableBorrowRateEnabled)
    external
    onlyPoolAdmin
  {
    DataTypes.ReserveConfigurationMap memory currentConfig = pool.getConfiguration(asset);

    currentConfig.setBorrowingEnabled(true);
    currentConfig.setStableRateBorrowingEnabled(stableBorrowRateEnabled);

    pool.setConfiguration(asset, currentConfig.data);

    emit BorrowingEnabledOnReserve(asset, stableBorrowRateEnabled);
  }

  /**
   * @dev Disables borrowing on a reserve
   * @param asset The address of the underlying asset of the reserve
   **/
  
  // 이 함수는 위에 제공된 enableBorrowingOnReserve 함수와 기능적으로 비슷한데
  // 해당 함수에서는 제공된 asset에 대해 대출 기능을 비활성화하기 위해 제공되는 기능
  function disableBorrowingOnReserve(address asset) external onlyPoolAdmin {
    DataTypes.ReserveConfigurationMap memory currentConfig = pool.getConfiguration(asset);

    currentConfig.setBorrowingEnabled(false);

    pool.setConfiguration(asset, currentConfig.data);
    emit BorrowingDisabledOnReserve(asset);
  }

  /**
   * @dev Configures the reserve collateralization parameters
   * all the values are expressed in percentages with two decimals of precision. A valid value is 10000, which means 100.00%
   * @param asset The address of the underlying asset of the reserve
   * @param ltv The loan to value of the asset when used as collateral
   * @param liquidationThreshold The threshold at which loans using this asset as collateral will be considered undercollateralized
   * @param liquidationBonus The bonus liquidators receive to liquidate this asset. The values is always above 100%. A value of 105%
   * means the liquidator will receive a 5% bonus
   **/
  
  // 특정 Asset에 대한 담보에 관련된 정보를 설정하기 위한 함수
  // LTV나 LiquidationThreshold 및 LiquidationBonus 등을 새로 설정하기 위한 함수임
  // Liquidation Threshold는 대출과 담보가 담보의 부족으로 정의될 수 있는 비율을 의미함, 즉 대출과 담보의
  // 상호 임계치 수준을 의미함
  // 참고자료 : https://docs.aave.com/risk/v/master/asset-risk/risk-parameters
  function configureReserveAsCollateral(
    address asset,
    uint256 ltv,
    uint256 liquidationThreshold,
    uint256 liquidationBonus
  ) external onlyPoolAdmin {
    DataTypes.ReserveConfigurationMap memory currentConfig = pool.getConfiguration(asset);

    //validation of the parameters: the LTV can
    //only be lower or equal than the liquidation threshold
    //(otherwise a loan against the asset would cause instantaneous liquidation)
    // LTV : 특정 담보로 빌릴 수 있는 최대 통화 금액에 대한 비율
    // 이 때문에 LTV의 비율이 liquidation threshold보다 작아서는 안됨
    require(ltv <= liquidationThreshold, Errors.LPC_INVALID_CONFIGURATION);

    // 임계값이 0이 아닌 경우
    if (liquidationThreshold != 0) {
      //liquidation bonus must be bigger than 100.00%, otherwise the liquidator would receive less
      //collateral than needed to cover the debt

      // 여기서 Liquidation Bonus라는 청산되는 시점에 청산자가 얻게 되는 보너스는 무조건 기존 값에서
      // 100% 이상이 되어야 함, 그게 아닐 경우에는 청산자가 금리를 커버할 수 있을만큼의 담보의 양보다 적은 양을
      // 수신하게 되면서 손실이 발생함
      require(
        liquidationBonus > PercentageMath.PERCENTAGE_FACTOR,
        Errors.LPC_INVALID_CONFIGURATION
      );

      //if threshold * bonus is less than PERCENTAGE_FACTOR, it's guaranteed that at the moment
      //a loan is taken there is enough collateral available to cover the liquidation bonus
      // 임계치 비율 * 담보 보너스의 결과는 무조건 100.00% 보다 작아야 한다는데, 이건 아직 이유를 모르겠음
      require(
        liquidationThreshold.percentMul(liquidationBonus) <= PercentageMath.PERCENTAGE_FACTOR,
        Errors.LPC_INVALID_CONFIGURATION
      );
    } else {
      // 만일 임계값이 0일 경우에는 bonus 값도 0이 되어야 함
      require(liquidationBonus == 0, Errors.LPC_INVALID_CONFIGURATION);
      //if the liquidation threshold is being set to 0,
      // the reserve is being disabled as collateral. To do so,
      //we need to ensure no liquidity is deposited
      _checkNoLiquidity(asset);
    }

    currentConfig.setLtv(ltv);
    currentConfig.setLiquidationThreshold(liquidationThreshold);
    currentConfig.setLiquidationBonus(liquidationBonus);

    pool.setConfiguration(asset, currentConfig.data);

    emit CollateralConfigurationChanged(asset, ltv, liquidationThreshold, liquidationBonus);
  }

  /**
   * @dev Enable stable rate borrowing on a reserve
   * @param asset The address of the underlying asset of the reserve
   **/
  function enableReserveStableRate(address asset) external onlyPoolAdmin {
    DataTypes.ReserveConfigurationMap memory currentConfig = pool.getConfiguration(asset);

    currentConfig.setStableRateBorrowingEnabled(true);

    pool.setConfiguration(asset, currentConfig.data);

    emit StableRateEnabledOnReserve(asset);
  }

  /**
   * @dev Disable stable rate borrowing on a reserve
   * @param asset The address of the underlying asset of the reserve
   **/
  function disableReserveStableRate(address asset) external onlyPoolAdmin {
    DataTypes.ReserveConfigurationMap memory currentConfig = pool.getConfiguration(asset);

    currentConfig.setStableRateBorrowingEnabled(false);

    pool.setConfiguration(asset, currentConfig.data);

    emit StableRateDisabledOnReserve(asset);
  }

  /**
   * @dev Activates a reserve
   * @param asset The address of the underlying asset of the reserve
   **/
  
  // 해당 에셋이 활성화가 되었는지 아닌지를 설정
  // 활성화가 되어야지 LendingPool을 통해 사용자들이 접근해서 오퍼레이션을 수행할 수 있음
  function activateReserve(address asset) external onlyPoolAdmin {
    DataTypes.ReserveConfigurationMap memory currentConfig = pool.getConfiguration(asset);

    currentConfig.setActive(true);

    pool.setConfiguration(asset, currentConfig.data);

    emit ReserveActivated(asset);
  }

  /**
   * @dev Deactivates a reserve
   * @param asset The address of the underlying asset of the reserve
   **/
  
  // 이는 activeReserve와 완전히 반대되는 명령
  // 해당 에셋을 비활성화하여 사용하지 못하도록 만드는 명령
  function deactivateReserve(address asset) external onlyPoolAdmin {
    _checkNoLiquidity(asset);

    DataTypes.ReserveConfigurationMap memory currentConfig = pool.getConfiguration(asset);

    currentConfig.setActive(false);

    pool.setConfiguration(asset, currentConfig.data);

    emit ReserveDeactivated(asset);
  }

  /**
   * @dev Freezes a reserve. A frozen reserve doesn't allow any new deposit, borrow or rate swap
   *  but allows repayments, liquidations, rate rebalances and withdrawals
   * @param asset The address of the underlying asset of the reserve
   **/
  function freezeReserve(address asset) external onlyPoolAdmin {
    DataTypes.ReserveConfigurationMap memory currentConfig = pool.getConfiguration(asset);

    currentConfig.setFrozen(true);

    pool.setConfiguration(asset, currentConfig.data);

    emit ReserveFrozen(asset);
  }

  /**
   * @dev Unfreezes a reserve
   * @param asset The address of the underlying asset of the reserve
   **/
  function unfreezeReserve(address asset) external onlyPoolAdmin {
    DataTypes.ReserveConfigurationMap memory currentConfig = pool.getConfiguration(asset);

    currentConfig.setFrozen(false);

    pool.setConfiguration(asset, currentConfig.data);

    emit ReserveUnfrozen(asset);
  }

  /**
   * @dev Updates the reserve factor of a reserve
   * @param asset The address of the underlying asset of the reserve
   * @param reserveFactor The new reserve factor of the reserve
   **/
  function setReserveFactor(address asset, uint256 reserveFactor) external onlyPoolAdmin {
    DataTypes.ReserveConfigurationMap memory currentConfig = pool.getConfiguration(asset);

    currentConfig.setReserveFactor(reserveFactor);

    pool.setConfiguration(asset, currentConfig.data);

    emit ReserveFactorChanged(asset, reserveFactor);
  }

  /**
   * @dev Sets the interest rate strategy of a reserve
   * @param asset The address of the underlying asset of the reserve
   * @param rateStrategyAddress The new address of the interest strategy contract
   **/
  // 여기서는 내부적으로 활용할 Interest Rate를 계산하기 위한 모델을 새로 설정해주는 기능을 수행함
  function setReserveInterestRateStrategyAddress(address asset, address rateStrategyAddress)
    external
    onlyPoolAdmin
  {
    pool.setReserveInterestRateStrategyAddress(asset, rateStrategyAddress);
    emit ReserveInterestRateStrategyChanged(asset, rateStrategyAddress);
  }

  /**
   * @dev pauses or unpauses all the actions of the protocol, including aToken transfers
   * @param val true if protocol needs to be paused, false otherwise
   **/
  function setPoolPause(bool val) external onlyEmergencyAdmin {
    pool.setPause(val);
  }


  // 여기서 Token에 대해서 Proxy를 적용하는 이유는 이후에 해당 기능에 대한 확장, 업데이터 등을
  // 수행하기에 용이하도록 만들기 위해서 사용하는 것임
  function _initTokenWithProxy(address implementation, bytes memory initParams)
    internal
    returns (address)
  {
    InitializableImmutableAdminUpgradeabilityProxy proxy =
      new InitializableImmutableAdminUpgradeabilityProxy(address(this));

    proxy.initialize(implementation, initParams);

    return address(proxy);
  }

  function _upgradeTokenImplementation(
    address proxyAddress,
    address implementation,
    bytes memory initParams
  ) internal {
    InitializableImmutableAdminUpgradeabilityProxy proxy =
      InitializableImmutableAdminUpgradeabilityProxy(payable(proxyAddress));

    proxy.upgradeToAndCall(implementation, initParams);
  }

  function _checkNoLiquidity(address asset) internal view {
    DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);

    uint256 availableLiquidity = IERC20Detailed(asset).balanceOf(reserveData.aTokenAddress);

    require(
      availableLiquidity == 0 && reserveData.currentLiquidityRate == 0,
      Errors.LPC_RESERVE_LIQUIDITY_NOT_0
    );
  }
}
