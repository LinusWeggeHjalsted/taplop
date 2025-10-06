using UnityEngine;

public class SpearScript : MonoBehaviour, Weapon, MainHandScript, ItemScript
{
    public bool finishedBuilding = false;
    public GameObject firstSkillPrefab;
    private GameObject firstSkill;
    public GameObject secondSkillPrefab;
    private GameObject secondSkill;
    public Sprite itemSprite;
    public string itemType;
    public string itemName;
    private int damage = 1;

    public GameObject FirstSkill()
    {
        return firstSkill;
    }

    public GameObject SecondSkill()
    {
        return secondSkill;
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

    public string ItemType()
    {
        return itemType;
    }

    void Start()
    {
        firstSkillPrefab = Resources.Load<GameObject>("Prefabs/Impale");
        firstSkill = Instantiate(firstSkillPrefab, this.transform);
        secondSkillPrefab = Resources.Load<GameObject>("Prefabs/Toss");
        secondSkill = Instantiate(secondSkillPrefab, this.transform);
        itemSprite = Resources.Load<Sprite>("Items/SpearItem");
        itemType = "Main Hand Weapon";
        finishedBuilding = true;
    }
}
