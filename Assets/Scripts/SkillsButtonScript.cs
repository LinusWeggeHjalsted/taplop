using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;

public class SkillsButtonScript : MonoBehaviour
{
    public Button button;
    public Transform characterUI;
    public GameObject skillsUIPrefab;
    public GameObject skillsUIPanel;

    public void OnActivate()
    {
        if (skillsUIPanel == null)
        {
            skillsUIPanel = Instantiate(skillsUIPrefab, characterUI);
        }
        else
        {
            Destroy(skillsUIPanel);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        characterUI = GameObject.Find("Character UI").transform;
        skillsUIPrefab = Resources.Load<GameObject>("Prefabs/Skills UI Panel");
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard != null)
        {
            if (keyboard.pKey.wasPressedThisFrame)
            {
                OnActivate();
            }
        }
    }
}
