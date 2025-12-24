using UnityEngine;

public class ShieldScript : MonoBehaviour, WeaponScript, ItemScript
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
        string damageString = "Damage " + damage.ToString();
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
        int fractionValue = totalValue / 4;
        salvage.metal = fractionValue;
        salvage.wood = totalValue - fractionValue;
        return salvage;
    }

    void Start()
    {
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/Skills/Bash");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        secondSkillPrefab = Resources.Load<GameObject>("Prefabs/Skills/Slam");
        secondSkill = Instantiate(secondSkillPrefab, this.transform);
        thirdSkillPrefab = Resources.Load<GameObject>("Prefabs/Skills/Reflect");
        thirdSkill = Instantiate(thirdSkillPrefab, this.transform);
        itemSprite = Resources.Load<Sprite>("Items/ShieldItem");
        itemType = "Weapon";
        itemSubType = "Shield";
        finishedBuilding = true;
    }
}
