using UnityEngine;

public class AxeScript : MonoBehaviour, WeaponScript, ItemScript
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    private GameObject firstSkill;
    public GameObject secondSkillPrefab;
    private GameObject secondSkill;
    public GameObject thirdSkillPrefab;
    private GameObject thirdSkill;
    public Sprite itemSprite;
    public string itemType;
    public string itemSubType;
    public string itemName;
    private int damage;
    private int _inventoryPosition;
    public int inventoryPosition
    {
        get
        {
            return _inventoryPosition;
        }
        set
        {
            _inventoryPosition = value;
        }
    }

    public GameObject FirstSkill()
    {
        return firstSkill;
    }

    public GameObject SecondSkill()
    {
        return secondSkill;
    }

    public GameObject ThirdSkill()
    {
        return thirdSkill;
    }

    public bool IsFinishedBuilding()
    {
        return finishedBuilding;
    }

    public int GetDamage()
    {
        return damage;
    }

    public void SetDamage(int number)
    {
        damage = number;
    }

    public Sprite GetSprite()
    {
        return itemSprite;
    }

    public string ItemName()
    {
        return itemName;
    }

    public string ItemDescription()
    {
        GameObject player = GameReferences.GetPlayer();
        PlayerCharacterScript playerScript = player.GetComponent<PlayerCharacterScript>();
        GameObject equippedMainHand = playerScript.mainHandWeapon;
        GameObject equippedOffHand = playerScript.offHandWeapon;
        string mainHandDifferenceString = "";
        string offHandDifferenceString = "";

        if (equippedMainHand == null)
        {
            mainHandDifferenceString = $"<color=#00FF00>+{damage.ToString()}</color>";
        }
        else
        {
            WeaponScript mainHandScript = equippedMainHand.GetComponent<WeaponScript>();
            int mainHandDifference = damage - mainHandScript.GetDamage();
            if (mainHandDifference > 0)
            {
                mainHandDifferenceString = $"<color=#00FF00>+{mainHandDifference.ToString()}</color>";
            }
            else if (mainHandDifference < 0)
            {
                mainHandDifferenceString = $"<color=#FF0000>-{Mathf.Abs(mainHandDifference).ToString()}</color>";
            }
            else
            {
                mainHandDifferenceString = "<color=#FFFFFF80>0</color>";
            }
        }

        if (equippedOffHand == null)
        {
            offHandDifferenceString = $"<color=#00FF00>+{damage.ToString()}</color>";
        }
        else
        {
            WeaponScript offHandScript = equippedOffHand.GetComponent<WeaponScript>();
            int offHandDifference = damage - offHandScript.GetDamage();
            if (offHandDifference > 0)
            {
                offHandDifferenceString = $"<color=#00FF00>+{offHandDifference.ToString()}</color>";
            }
            else if (offHandDifference < 0)
            {
                offHandDifferenceString = $"<color=#FF0000>-{Mathf.Abs(offHandDifference).ToString()}</color>";
            }
            else
            {
                offHandDifferenceString = "<color=#FFFFFF80>0</color>";
            }
        }

        string damageString = $"Damage {damage.ToString()} <color=#FFFFFF80>[</color>{mainHandDifferenceString}<color=#FFFFFF80>,</color> {offHandDifferenceString}<color=#FFFFFF80>]</color>";
        return damageString;
    }

    public string ItemType()
    {
        return itemType;
    }

    public string ItemSubType()
    {
        return itemSubType;
    }

    public void SetItemName(string newItemName)
    {
        itemName = newItemName;
    }

    public PlayerDataScript.Salvage SalvageValue()
    {
        PlayerDataScript.Salvage salvage = new PlayerDataScript.Salvage();
        int totalValue = damage;
        int fractionValue = totalValue / 2;
        salvage.wood = fractionValue;
        salvage.metal = totalValue - fractionValue;
        return salvage;
    }

    void Awake()
    {
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/Skills/Chop");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        secondSkillPrefab = Resources.Load<GameObject>("Prefabs/Skills/Cleave");
        secondSkill = Instantiate(secondSkillPrefab, this.transform);
        thirdSkillPrefab = Resources.Load<GameObject>("Prefabs/Skills/Throw");
        thirdSkill = Instantiate(thirdSkillPrefab, this.transform);
        itemSprite = Resources.Load<Sprite>("Items/AxeItem");
        itemType = "Weapon";
        itemSubType = "Axe";
        finishedBuilding = true;
    }
}
