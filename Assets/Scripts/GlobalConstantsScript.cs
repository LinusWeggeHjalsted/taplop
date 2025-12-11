using UnityEngine;

public class GlobalConstantsScript : MonoBehaviour
{
    public static GlobalConstantsScript Instance { get; private set; }
    public int maxWeaponDamage = 10;
    public int maxArmor = 5;
    public int maxHealthBonus = 20;
    public int maxDamageBonus = 5;
    public int maxPickupRadius = 2;
    public int maxSpeedBonus = 2;
    public int maxUtilitySkillSlots = 5;
    public int maxFullUpgradeCost; // to-do - think about this
    public int maxSalvage;

    void Awake()
    {
        if (Instance == null)
        {
            Instance = this;
            DontDestroyOnLoad(this.gameObject);
        }
        else
        {
            Destroy(this.gameObject);
        }
    }
}
