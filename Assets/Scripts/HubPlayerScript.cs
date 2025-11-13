using UnityEngine;

public class HubPlayerScript : MonoBehaviour, PlayerCharacterScript
{
    private bool _finishedBuilding = false;
    public bool finishedBuilding
    {
        get
        {
            return _finishedBuilding;
        }
        set
        {
            _finishedBuilding = value;
        }
    }
    public GameObject hubBuilder;
    public HubBuilderScript hubBuilderScript;
    public GameObject hubTiles;
    public HubTilesScript hubTilesScript;
    public GameObject hubExits;
    public HubExitsScript hubExitsScript;

    public GameObject gear;
    public GearScript gearScript;

    private Transform _mainHand;
    private Transform _offHand;
    private Transform _hands;
    private Transform _body;
    private Transform _feet;
    private Transform _inventory;
    private int _inventorySize;
    private Transform _utilitySkills;
    private int _utilitySkillSlots;

    public Transform mainHand { get { return _mainHand; } }
    public Transform offHand { get { return _offHand; } }
    public Transform hands { get { return _hands; } }
    public Transform body { get { return _body; } }
    public Transform feet { get { return _feet; } }
    public Transform inventory { get { return _inventory; } }
    public int inventorySize { get { return _inventorySize; } }
    public Transform utilitySkills { get { return _utilitySkills; } }
    public int utilitySkillSlots 
    {
        get
        {
            return _utilitySkillSlots;
        }
        set
        {
            _utilitySkillSlots = value;
        }
    }

    public GameObject mainHandWeapon
    {
        get
        {
            if (mainHand.childCount == 0) return null;
            return mainHand.GetChild(0).gameObject;
        }
    }
    public GameObject offHandWeapon
    {
        get
        {
            if (offHand.childCount == 0) return null;
            return offHand.GetChild(0).gameObject;
        }
    }
    public GameObject gloves
    {
        get
        {
            if (hands.childCount == 0) return null;
            return hands.GetChild(0).gameObject;
        }
    }
    public GameObject coat
    {
        get
        {
            if (body.childCount == 0) return null;
            return body.GetChild(0).gameObject;
        }
    }
    public GameObject boots
    {
        get
        {
            if (feet.childCount == 0) return null;
            return feet.GetChild(0).gameObject;
        }
    }
    public GameObject[] inventoryItems
    {
        get
        {
            GameObject[] itemArray = new GameObject[inventorySize];
            for (int i = 0; i < inventory.childCount; i++)
            {
                if (i < inventorySize)
                {
                    itemArray[i] = inventory.GetChild(i).gameObject;
                }
                else
                {
                    Debug.LogError("entity has more items in inventory than inventorySize " + inventorySize.ToString() + " allows");
                }
            }
            return itemArray;
        }
    }
    public GameObject[] equippedSkills
    {
        get
        {
            GameObject[] skillArray = new GameObject[8];
            if (mainHandWeapon != null)
            {
                WeaponScript mainHandWeaponScript = mainHandWeapon.GetComponent<WeaponScript>();
                skillArray[0] = mainHandWeaponScript.FirstSkill();
                skillArray[1] = mainHandWeaponScript.SecondSkill();
            }
            if (offHandWeapon != null)
            {
                WeaponScript offHandWeaponScript = offHandWeapon.GetComponent<WeaponScript>();
                skillArray[2] = offHandWeaponScript.ThirdSkill();
            }
            if (utilitySkills.childCount > 0)
            {
                for (int i = 0; i < utilitySkills.childCount; i++)
                {
                    if (i < utilitySkillSlots)
                    {
                        skillArray[i + 3] = utilitySkills.GetChild(i).gameObject;
                    }
                }
            }
            return skillArray;
        }
    }

    void Start()
    {
        hubBuilder = GameObject.Find("Hub Builder");
        hubBuilderScript = hubBuilder.GetComponent<HubBuilderScript>();
        hubTiles = GameObject.Find("Hub Tiles");
        hubTilesScript = hubTiles.GetComponent<HubTilesScript>();
        hubExits = GameObject.Find("Hub Exits");
        hubExitsScript = hubExits.GetComponent<HubExitsScript>();
        _mainHand = gear.transform.Find("Main Hand");
        _offHand = gear.transform.Find("Off Hand");
        _body = gear.transform.Find("Body");
        _hands = gear.transform.Find("Hands");
        _feet = gear.transform.Find("Feet");
        _inventory = this.transform.Find("Inventory");
        _inventorySize = 24;
        _utilitySkills = this.transform.Find("Utility Skills");
    }
}
