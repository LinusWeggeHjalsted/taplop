using UnityEngine;
using UnityEngine.InputSystem;
using System.Collections;

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
    public SpriteRenderer spriteRenderer;

    public GameObject gear;
    public GearScript gearScript;

    private Transform _mainHand;
    private Transform _offHand;
    private Transform _body;
    private Transform _hands;
    private Transform _legs;
    private Transform _feet;
    private Transform _inventory;
    private int _inventorySize;
    private Transform _utilitySkills;
    private int _utilitySkillSlots;

    public Transform mainHand { get { return _mainHand; } }
    public Transform offHand { get { return _offHand; } }
    public Transform body { get { return _body; } }
    public Transform hands { get { return _hands; } }
    public Transform legs { get { return _legs; } }
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
    public GameObject pants
    {
        get
        {
            if (legs.childCount == 0) return null;
            return legs.GetChild(0).gameObject;
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
                        GameObject utilitySkill = utilitySkills.GetChild(i).gameObject;
                        Skill skillScript = utilitySkill.GetComponent<Skill>();
                        int skillIndex = skillScript.skillBarPosition - 1;
                        if (skillArray[skillIndex] != null)
                        {
                            Debug.LogError($"there is already a skill in slot {skillIndex}");
                        }
                        else
                        {
                            skillArray[skillIndex] = utilitySkill;
                        }
                    }
                }
            }
            return skillArray;
        }
    }
    private int speed = 1;
    public int Speed
    {    
        get
        {
            BootsScript bootsScript = boots.GetComponent<BootsScript>();
            return speed + bootsScript.speedBonus;
        }
    }
    private float moveTimer = 0;
    private float baseMoveDelay = 0.3f;
    private float moveDelay
    {
        get
        {
            return baseMoveDelay / (float)Speed;
        }
    }

    public void MoveTo(Vector3 targetPosition)
    {
        // flip sprite if moving left, unflip if moving right
        Vector3 currentPosition = this.transform.position;
        float xDif = targetPosition.x - currentPosition.x;
        if (xDif < 0)
        {
            spriteRenderer.flipX = true;
        }
        if (xDif > 0)
        {
            spriteRenderer.flipX = false;
        }
        this.transform.position = targetPosition;
        // start mission if standing on exit
        if (hubExitsScript.exitLookup.ContainsKey(targetPosition))
        {
            GameObject exit = hubExitsScript.exitLookup[targetPosition];
            ExitScript exitScript = exit.GetComponent<ExitScript>();
            string missionName = exitScript.missionName;
            int missionLength = exitScript.missionLength;
            string endHub = exitScript.endHub;
            PlayerDataScript.Instance.BuildDataFromPlayer(this.gameObject);
            GameControllerScript.Instance.StartMission(missionName, missionLength, endHub);
        }
    }

    public int GetSkillCooldown(string skillName)
    {
        return 0;
    }

    public void SetSkillCooldown(string skillName, int number)
    {
    }

    IEnumerator WaitForGear()
    {
        while (!gearScript.finishedBuilding)
        {
            yield return null;
        }
        finishedBuilding = true;
    }

    void Start()
    {
        hubBuilder = GameObject.Find("Hub Builder");
        hubBuilderScript = hubBuilder.GetComponent<HubBuilderScript>();
        hubTiles = GameObject.Find("Hub Tiles");
        hubTilesScript = hubTiles.GetComponent<HubTilesScript>();
        hubExits = GameObject.Find("Hub Exits");
        hubExitsScript = hubExits.GetComponent<HubExitsScript>();
        spriteRenderer = this.gameObject.GetComponent<SpriteRenderer>();
        gear = this.transform.Find("Gear").gameObject;
        gearScript = gear.GetComponent<GearScript>();
        _mainHand = gear.transform.Find("Main Hand");
        _offHand = gear.transform.Find("Off Hand");
        _body = gear.transform.Find("Body");
        _hands = gear.transform.Find("Hands");
        _legs = gear.transform.Find("Legs");
        _feet = gear.transform.Find("Feet");
        _inventory = this.transform.Find("Inventory");
        _inventorySize = 24;
        _utilitySkills = this.transform.Find("Utility Skills");
        StartCoroutine(WaitForGear());
    }

    void Update()
    {
        moveTimer += Time.deltaTime;
        Keyboard keyboard = Keyboard.current;
        if (keyboard == null) return;

        float horizontalInput = 0;
        float verticalInput = 0;
        if (keyboard.rightArrowKey.isPressed || keyboard.dKey.isPressed)
        {
            horizontalInput = 1;
        }
        if (keyboard.leftArrowKey.isPressed || keyboard.aKey.isPressed)
        {
            horizontalInput = -1;
        }
        if (keyboard.upArrowKey.isPressed || keyboard.wKey.isPressed)
        {
            verticalInput = 1;
        }
        if (keyboard.downArrowKey.isPressed || keyboard.sKey.isPressed)
        {
            verticalInput = -1;
        }
        if (horizontalInput != 0 || verticalInput != 0)
        {
            if (moveTimer >= moveDelay)
            {
                Vector3 moveDelta = new Vector3(horizontalInput, verticalInput, 0);
                Vector3 targetPosition = this.transform.position + moveDelta;
                if (hubTilesScript.tileLookup.ContainsKey(targetPosition))
                {
                    MoveTo(targetPosition);
                    moveTimer = 0;
                }
            }
        }
    }
}
